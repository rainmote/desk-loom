(ns desktop.memory
  "Local page memory. Stored page text is untrusted historical data, never instructions
   or live accessibility handles. Execution always requires a fresh observation."
  (:refer-clojure :exclude [search])
  (:require [clojure.data.json :as json]
            [clojure.string :as str]
            [xtdb.api :as xt])
  (:import [java.nio.charset StandardCharsets]
           [java.security MessageDigest]
           [java.time Instant]
           [java.util HexFormat UUID]))

(def ^:private max-nodes 5000)
(def ^:private max-content-bytes (* 8 1024 1024))
(def ^:private node-text-fields [:role :subrole :title :label :description :identifier :url])
(def ^:private node-state-fields [:enabled :settable :selected :value_truncated :secure :value_redacted])

(defn- invalid! [message field]
  (throw (ex-info message {:code :invalid-memory-input :field field})))

(defn- bounded-string [value field maximum required?]
  (when (or (and required? (or (not (string? value)) (str/blank? value)))
            (and (some? value) (or (not (string? value)) (> (count value) maximum))))
    (invalid! (str (name field) " must be " (when-not required? "an optional ")
                   "string of at most " maximum " characters") field))
  value)

(defn- canonical [value]
  (cond (map? value) (into (sorted-map) (map (fn [[k v]] [k (canonical v)])) value)
        (sequential? value) (mapv canonical value)
        :else value))

(defn- encode [value] (json/write-str (canonical value)))
(defn- decode [value] (json/read-str value :key-fn keyword))
(defn- sha256 [^String value]
  (.formatHex (HexFormat/of)
              (.digest (MessageDigest/getInstance "SHA-256")
                       (.getBytes value StandardCharsets/UTF_8))))

(defn- normalize-node [node indices]
  (when-not (map? node) (invalid! "Each node must be an object" :nodes))
  (doseq [field node-text-fields]
    (bounded-string (get node field) field 8192 (= field :role)))
  (doseq [field node-state-fields :when (contains? node field)]
    (when-not (boolean? (get node field)) (invalid! "Node flags must be booleans" field)))
  (let [redacted? (or (true? (:secure node)) (true? (:value_redacted node))
                      (= "AXSecureTextField" (:subrole node)) (= "AXSecureTextField" (:role node)))
        ;; Defense in depth: do not trust an adapter to have stripped passwords.
        node (cond-> node redacted? (dissoc :value) redacted? (assoc :value_redacted true))
        value (:value node)
        actions (or (:actions node) [])]
    (when-not (or (nil? value) (boolean? value)
                  (and (number? value) (Double/isFinite (double value)))
                  (and (string? value) (<= (count value) 131072)))
      (invalid! "Node value must be a bounded string, finite number, boolean or null" :value))
    (when-not (and (sequential? actions) (<= (bounded-count 129 actions) 128)
                   (every? #(and (string? %) (<= (count %) 256)) actions))
      (invalid! "Node actions must contain at most 128 short action names" :actions))
    (let [parent-index (get indices (:parent_id node))]
      (cond-> (assoc (select-keys node (concat node-text-fields node-state-fields [:value]))
                     :actions (vec (sort (distinct actions))))
        (some? parent-index) (assoc :parent_index parent-index)))))

(defn- normalize-snapshot [snapshot]
  (when-not (map? snapshot) (invalid! "Snapshot must be an object" :snapshot))
  (let [app (:app snapshot)
        window (:window snapshot)
        bundle (or (:bundle_id app) (:bundle_id snapshot))
        title (or (:title window) (:window_title snapshot) "")
        declared-url (or (:url window) (:url snapshot))
        nodes (:nodes snapshot)]
    (bounded-string bundle :bundle_id 512 true)
    (bounded-string title :window_title 8192 false)
    (bounded-string declared-url :url 8192 false)
    (bounded-string (:name app) :app_name 1024 false)
    (bounded-string (:session_id snapshot) :session_id 512 false)
    (bounded-string (:snapshot_id snapshot) :snapshot_id 512 false)
    (when-not (and (sequential? nodes) (<= (bounded-count (inc max-nodes) nodes) max-nodes))
      (invalid! "Snapshot nodes must be a sequence of at most 5000 nodes" :nodes))
    (when-not (or (nil? (:complete snapshot)) (boolean? (:complete snapshot)))
      (invalid! "Snapshot complete must be a boolean" :complete))
    (doseq [node nodes] (bounded-string (:id node) :node_id 512 false))
    (let [ids (keep :id nodes)]
      (when-not (= (count ids) (count (distinct ids)))
        (invalid! "Snapshot node IDs must be unique" :nodes)))
    (let [indices (into {} (keep-indexed (fn [i n] (when (:id n) [(:id n) i])) nodes))
          semantic-nodes (mapv #(normalize-node % indices) nodes)
          web-urls (->> semantic-nodes (filter #(= "AXWebArea" (:role %)))
                        (keep :url) (remove str/blank?) distinct vec)
          url (if-not (str/blank? declared-url) declared-url
                      (when (= 1 (count web-urls)) (first web-urls)))
          normalized {:app (cond-> {:bundle_id bundle} (:name app) (assoc :name (:name app)))
                      :window (cond-> {:title title} (not (str/blank? url)) (assoc :url url))
                      :complete (true? (:complete snapshot))
                      :nodes semantic-nodes}
          payload (encode normalized)]
      (when (> (alength (.getBytes payload StandardCharsets/UTF_8)) max-content-bytes)
        (invalid! "Semantic page content exceeds the 8 MiB limit" :snapshot))
      {:snapshot normalized :payload payload
       ;; Window IDs and PIDs are process-local and cannot identify a durable page.
       :page-id (str "page-" (sha256 (encode [bundle (if (str/blank? url)
                                                                  ["title" title] ["url" url])])))
       :hash (sha256 payload)})))

(defn- selectors [nodes]
  (->> nodes
       (map #(into {} (remove (fn [[_ v]] (or (nil? v) (and (string? v) (str/blank? v)))))
                   (select-keys % [:role :subrole :title :label :description :identifier :settable :enabled])))
       frequencies
       (sort-by (comp encode key))
       (mapv (fn [[selector matches]]
               {:selector selector :matches matches :ambiguous (> matches 1)
                :requires_fresh_observation true}))))

(defn- search-text [snapshot]
  (str/lower-case
   (str/join "\n" (concat [(get-in snapshot [:app :bundle_id])
                            (get-in snapshot [:app :name])
                            (get-in snapshot [:window :title])
                            (get-in snapshot [:window :url])]
                           (mapcat #(map % (conj node-text-fields :value)) (:nodes snapshot))))))

(defn- query-memory [store sql-args]
  (try
    (xt/q (:node store) sql-args {:key-fn :snake-case-keyword})
    (catch Exception error
      ;; XTDB creates schemaless tables on their first put. An empty new store
      ;; therefore has no memory tables yet; every other planning/storage error
      ;; must propagate rather than masquerade as an empty result.
      (if (and (= :xtdb/sql-error (:xtdb.error/code (ex-data error)))
               (some #(contains? #{["desktop_pages"] ["desktop_page_versions"]}
                                 (mapv str (:table-chain %)))
                     (:errors (ex-data error))))
        []
        (throw error)))))

(defn- page [store page-id]
  (first (query-memory store ["SELECT * FROM desktop_pages WHERE page_id = ?" page-id])))

(defn- public-page [row]
  (when row
    (-> (select-keys row [:page_id :bundle_id :title :url :content_hash :version_id
                         :visit_count :node_count :complete :first_seen :last_visited])
        (update :first_seen str)
        (update :last_visited str)
        (assoc :historical true :executable false :content_trust "untrusted"))))

(defn remember!
  "Synchronously persist semantic page content and a compact visit in local XTDB.
   Repeated unchanged observations share one immutable content version; transient
   IDs, timestamps, bounds and PIDs never participate in page/content identity."
  [store snapshot]
  (let [{normalized :snapshot :keys [payload page-id hash]} (normalize-snapshot snapshot)]
    ;; The Store already excludes other processes. Serialize read-modify-write
    ;; across callers sharing it so visit counters and latest pointers stay exact.
    (locking store
      (let [previous (page store page-id)
            version-id (str page-id "/" hash)
            exists? (seq (query-memory store
                                ["SELECT version_id FROM desktop_page_versions WHERE version_id = ?" version-id]))
            now (Instant/now)
            count-visits (inc (long (or (:visit_count previous) 0)))
            observation (cond-> {:historical true :executable false}
                          (:snapshot_id snapshot) (assoc :historical_snapshot_id (:snapshot_id snapshot))
                          (:session_id snapshot) (assoc :historical_session_id (:session_id snapshot)))
            doc {:xt/id page-id :page_id page-id :content_hash hash :version_id version-id
                        :bundle_id (get-in normalized [:app :bundle_id])
                        :title (get-in normalized [:window :title])
                        :url (or (get-in normalized [:window :url]) "")
                        :visit_count count-visits :node_count (count (:nodes normalized))
                        :complete (:complete normalized) :first_seen (or (:first_seen previous) now)
                        :last_visited now :observation (encode observation)}
            visit {:xt/id (str (UUID/randomUUID)) :page_id page-id :version_id version-id
                   :at now :observation (encode observation)}
            tx (cond-> [[:put-docs :desktop_pages doc] [:put-docs :desktop_page_visits visit]]
                 (not exists?) (conj [:put-docs :desktop_page_versions
                                     {:xt/id version-id :version_id version-id :page_id page-id
                                      :content_hash hash :created_at now :payload payload
                                      :selectors (encode (selectors (:nodes normalized)))
                                      :search_text (search-text normalized)}]))]
        (xt/execute-tx (:node store) tx)
        {:page_id page-id :content_hash hash :version_id version-id
         :changed (not= hash (:content_hash previous)) :new_version (not (boolean exists?))
         :visit_count count-visits :visited_at (str now)}))))

(defn search
  "Search remembered page titles, URLs and semantic text. Query is a literal,
   case-insensitive substring, not SQL or a wildcard expression."
  [store options]
  (when-not (or (nil? options) (map? options)) (invalid! "Search options must be an object" :options))
  (let [{:keys [query bundle_id limit] :or {limit 20}} options]
    (bounded-string query :query 1024 false)
    (bounded-string bundle_id :bundle_id 512 false)
    (when-not (and (integer? limit) (<= 1 limit 100))
      (invalid! "Search limit must be an integer between 1 and 100" :limit))
    (let [clauses (cond-> []
                    (some? bundle_id) (conj "p.bundle_id = ?")
                    (not (str/blank? query)) (conj "POSITION(? IN v.search_text) > 0"))
          substring (when-not (str/blank? query) (str/lower-case query))
          sql (str "SELECT p.page_id, p.bundle_id, p.title, p.url, p.content_hash, p.version_id, "
                   "p.visit_count, p.node_count, p.complete, p.first_seen, p.last_visited "
                   "FROM desktop_pages p JOIN desktop_page_versions v ON p.version_id = v.version_id"
                   (when (seq clauses) (str " WHERE " (str/join " AND " clauses)))
                   " ORDER BY p.last_visited DESC, p.page_id LIMIT ?")
          args (cond-> [sql]
                 (some? bundle_id) (conj bundle_id)
                 substring (conj substring))]
      (mapv public-page (query-memory store (conj args limit))))))

(defn recall
  "Return the latest saved semantic snapshot and selectors, or nil. All data is
   historical and untrusted. Stored observations never supply executable handles."
  [store page-id]
  (bounded-string page-id :page_id 128 true)
  (when-let [saved (page store page-id)]
    (when-let [version (first (query-memory store
                                   ["SELECT payload, selectors FROM desktop_page_versions WHERE version_id = ?"
                                    (:version_id saved)]))]
      (assoc (public-page saved)
             :snapshot (assoc (decode (:payload version)) :historical true :executable false)
             :selectors (decode (:selectors version))
             :observation (decode (:observation saved))
             :handle_policy "Historical page memory contains no live handles. Observe again and resolve a unique semantic selector before acting."))))
