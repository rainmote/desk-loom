(ns desktop.agent
  "Provider-neutral computer-use service. One warm process owns XTDB and serializes actions."
  (:require [clojure.data.json :as json]
            [desktop.client :as client]
            [desktop.db :as db]
            [desktop.memory :as memory]
            [desktop.tools :as tools]
            [xtdb.api :as xt])
  (:import [java.time Instant]
           [java.security MessageDigest]
           [java.util HexFormat]))

(defn context
  ([] (context {}))
  ([options] {:options options :store (atom nil) :last-snapshot (atom nil)
              :session (atom nil) :sessions (atom {}) :native-client (atom nil)
              :observation-options (atom {}) :metrics (atom {})}))

(defn store! [ctx]
  (or @(:store ctx)
      (let [store (db/open! (or (get-in ctx [:options :db-path]) (db/default-path)))]
        (reset! (:store ctx) store) store)))

(defn native! [ctx method params]
  ;; Re-read endpoint on each call so a restarted native app does not strand the bridge.
  (let [fresh (if-let [path (get-in ctx [:options :endpoint])]
                (client/connect path (:http @(:native-client ctx)))
                (client/connect-default (:http @(:native-client ctx))))]
    (reset! (:native-client ctx) fresh)
    (client/rpc! fresh method params)))

(defn failure [code message] (throw (ex-info message {:code code})))

(def max-sessions 8)

(defn session-states [ctx]
  ;; Preserve the original single-session atoms for in-process integrations.
  ;; They are a mirror of the sole session, never a mutable routing context.
  (when (and (empty? @(:sessions ctx)) @(:session ctx))
    (let [sid @(:session ctx)]
      (swap! (:sessions ctx) assoc sid {:session {:session_id sid}
                                      :last-snapshot @(:last-snapshot ctx)
                                      :observation-options @(:observation-options ctx)})))
  @(:sessions ctx))

(defn sync-single-session! [ctx]
  (let [states @(:sessions ctx)
        [sid state] (when (= 1 (count states)) (first states))]
    (reset! (:session ctx) sid)
    (reset! (:last-snapshot ctx) (:last-snapshot state))
    (reset! (:observation-options ctx) (or (:observation-options state) {}))))

(defn resolve-session [ctx args]
  (let [states (session-states ctx)]
    (if-let [sid (:session_id args)]
      (if (contains? states sid) sid
        (failure :session-changed "This client does not own that session_id; attach the window first."))
      (case (count states)
        0 (failure :session-changed "Attach a window first; this client has no active sessions.")
        1 (first (keys states))
        (failure :session-required "Multiple windows are attached; supply session_id for the intended window.")))))

(defn set-session-value! [ctx sid key value]
  (swap! (:sessions ctx) assoc-in [sid key] value)
  (sync-single-session! ctx)
  value)

(defn last-snapshot [ctx sid] (get-in (session-states ctx) [sid :last-snapshot]))

(defn observe!
  ([ctx] (observe! ctx (resolve-session ctx {})))
  ([ctx session-id]
   (let [sid (resolve-session ctx {:session_id session-id})
         params (assoc (get-in (session-states ctx) [sid :observation-options]) :session_id sid)
         snapshot (native! ctx :computer_observe params)]
     (when-not (= sid (:session_id snapshot))
       (failure :session-changed "The native observation belongs to a different session."))
     (let [saved (memory/remember! (store! ctx) snapshot)
           result (assoc snapshot :memory saved :content_trust "untrusted")]
       (set-session-value! ctx sid :last-snapshot result)))))

(defn delta
  "Fresh tokens are always returned, even if semantic content is unchanged."
  [before after]
  (if (or (nil? before) (not= (:session_id before) (:session_id after)))
    (assoc after :mode "full")
    (let [old (:nodes before) nodes (:nodes after)
          semantic #(dissoc % :id :parent_id)
          changed (keep-indexed (fn [i node]
                                  (when (not= (semantic node) (semantic (get old i)))
                                    (assoc node :index i))) nodes)]
      (-> after
          (dissoc :nodes)
          (assoc :mode "delta" :base_snapshot_id (:snapshot_id before)
                 :node_ids (mapv :id nodes) :parent_ids (mapv :parent_id nodes) :node_count (count nodes)
                 :changed_nodes (vec changed)
                 :removed_indices (vec (range (count nodes) (count old))))))))

(defn select-node [snapshot selector]
  (when-not (true? (:complete snapshot))
    (failure :incomplete-snapshot "Selector actions require a complete accessibility tree."))
  (let [matches (filter #(and (not= false (:enabled %))
                             (every? (fn [[k v]] (= v (get % k))) selector)) (:nodes snapshot))]
    (when-not (= 1 (count matches))
      (failure :ambiguous-target (str "Selector must match exactly one enabled node; matched " (count matches) ".")))
    (first matches)))

(defn request-record [store request-id]
  (try
    (when-let [row (first (xt/q (:node store)
                               ["SELECT payload FROM desktop_requests WHERE _id = ?" request-id]))]
      (json/read-str (:payload row) :key-fn keyword))
    (catch Exception e
      (if (and (= :xtdb/sql-error (:xtdb.error/code (ex-data e)))
               (some #(= ["desktop_requests"] (mapv str (:table-chain %))) (:errors (ex-data e))))
        nil (throw e)))))

(defn save-request! [store request-id record]
  (xt/execute-tx (:node store)
                 [[:put-docs :desktop_requests
                   {:xt/id request-id :at (Instant/now) :payload (json/write-str record)}]]))

(defn signature-hash [value]
  (letfn [(canonical [v] (cond (map? v) (into (sorted-map) (map (fn [[k x]] [k (canonical x)]) v))
                               (sequential? v) (mapv canonical v) :else v))]
    (.formatHex (HexFormat/of)
                (.digest (MessageDigest/getInstance "SHA-256")
                         (.getBytes (json/write-str (canonical value)) java.nio.charset.StandardCharsets/UTF_8)))))

(defn durable-receipt [result]
  ;; The content version is already durable. Never duplicate the full tree in
  ;; the request ledger, nor return executable-looking tokens on receipt replay.
  (cond-> (dissoc result :observation)
    (:observation result)
    (assoc :observation_reference {:page_id (get-in result [:observation :memory :page_id])
                                  :version_id (get-in result [:observation :memory :version_id])
                                  :historical true :executable false})))

(defn once!
  "Durable intent before dispatch. Interrupted requests are never automatically replayed."
  [ctx request-id signature f]
  (let [store (store! ctx) signature (signature-hash signature)]
    (if-let [previous (request-record store request-id)]
      (do
        (when-not (= signature (:signature previous))
          (failure :request-conflict "request_id was already used with different arguments."))
        (if-let [result (:result previous)]
          (assoc result :replayed true :historical true)
          {:request_id request-id :outcome "unknown" :retry false
           :message "A prior attempt was interrupted. Observe current state; do not replay this action."}))
      (do
        (save-request! store request-id {:signature signature :state "pending"})
        (let [result (try (f)
                          (catch Exception e
                            {:request_id request-id :outcome "unknown" :retry false :is_error true
                             :code (str (or (:code (ex-data e)) :operation-failed))
                             :message (.getMessage e)}))]
          (try
            (save-request! store request-id {:signature signature :state "complete" :result (durable-receipt result)})
            result
            (catch Exception _
              {:request_id request-id :outcome "unknown" :retry false :is_error true
               :code "persistence-failed" :message "Action may have run; receipt could not be committed. Observe before continuing."})))))))

(defn perform!
  "One dispatch, followed by one fresh observation; no sleeps or mutation retries."
  [ctx args]
  (let [sid (resolve-session ctx args)
        before (if (:selector args)
                 (observe! ctx sid)
                 (let [s (last-snapshot ctx sid)]
                   (when-not (and s (= sid (:session_id s)) (= (:snapshot_id args) (:snapshot_id s)))
                     (failure :stale-target "Use the latest observation's snapshot_id, or provide a semantic selector.")) s))
        _ (when (and (:node_id args) (not-any? #(= (:node_id args) (:id %)) (:nodes before)))
            (failure :stale-target "node_id must belong to the latest observation of this session_id."))
        target (when-let [selector (:selector args)] (select-node before selector))
        params (cond-> (assoc (dissoc args :selector :observe_after) :session_id sid)
                 target (assoc :node_id (:id target) :snapshot_id (:snapshot_id before)))
        store (store! ctx)]
    ;; Text entered in secure fields must never be copied into the durable intent.
    ;; Store only shape/length for all supplied text; page memory captures actual
    ;; nonsecure readback separately, and dedup uses a digest instead of plaintext.
    (db/event! store sid :computer-action-intent
               (cond-> (dissoc params :value :text)
                 (:value params) (assoc :value_length (count (:value params)))
                 (:text params) (assoc :text_length (count (:text params)))))
    ;; An interrupted native request may already have mutated the window.
    ;; Retire only its tokens before dispatch, including when RPC throws.
    (set-session-value! ctx sid :last-snapshot nil)
    (let [receipt (native! ctx :computer_act params)]
      (db/event! store sid :computer-action-result receipt)
      ;; Even when the agent omits the returned tree, visited pages are saved.
      (let [after (try {:observation (observe! ctx sid)}
                       (catch Exception e {:observation_error {:message (.getMessage e)
                                                               :code (str (:code (ex-data e)))}}))]
        (cond-> (merge receipt after)
          (false? (:observe_after args)) (dissoc :observation))))))

(defn act! [ctx args]
  (let [args (assoc args :session_id (resolve-session ctx args))]
    (once! ctx (:request_id args) {:tool "computer_act" :arguments args}
           #(perform! ctx args))))

(defn batch! [ctx {:keys [request_id steps] :as args}]
  (let [sid (resolve-session ctx args)
        args (assoc args :session_id sid)]
   (once! ctx request_id {:tool "computer_batch" :arguments args}
         #(loop [remaining steps index 0 results []]
            (if-let [step (first remaining)]
              (let [result (try
                             (let [fresh (when-not (:selector step)
                                           (if (zero? index) (observe! ctx sid)
                                             (or (last-snapshot ctx sid) (observe! ctx sid))))
                                   action (cond-> (assoc step :session_id sid :request_id (str request_id "/" index) :observe_after false)
                                            fresh (assoc :snapshot_id (:snapshot_id fresh)))]
                               (act! ctx action))
                             (catch Exception e {:outcome "unknown" :is_error true :retry false
                                                 :code (str (:code (ex-data e))) :message (.getMessage e)}))
                    results (conj results result)]
                (if (or (:is_error result) (:observation_error result)
                        (not (#{"verified" "dispatched"} (:outcome result))))
                  {:request_id request_id :outcome "stopped" :steps results :completed index :retry false}
                  (recur (next remaining) (inc index) results)))
              {:session_id sid :request_id request_id :outcome "dispatched" :completed index :steps results
               :observation (last-snapshot ctx sid)})))))

(defn attach! [ctx args]
  ;; Acquire the durable store before taking control. Only this client's
  ;; sessions enter its ownership map; native duplicate errors leave it intact.
  (store! ctx)
  (let [states (session-states ctx)]
    (when (>= (count states) max-sessions)
      (failure :session-limit "A client may control at most eight windows; detach one first."))
    (let [session (native! ctx :computer_attach args)
          sid (:session_id session)]
      (when-not (and (string? sid) (seq sid))
        (failure :session-changed "Native attach did not return a session_id."))
      (when-not (contains? states sid)
        (swap! (:sessions ctx) assoc sid {:session session :last-snapshot nil :observation-options {}})
        (sync-single-session! ctx)
        (db/event! (store! ctx) sid :computer-attach session))
      (assoc session :observation (observe! ctx sid)))))

(defn capabilities! [ctx]
  (let [native (native! ctx :computer_capabilities {})
        _ (session-states ctx)
        ;; A native restart or a closed window can retire a session outside this
        ;; process. The native registry is authoritative when it is available.
        _ (when (vector? (:sessions native))
            (let [active-ids (set (map :session_id (:sessions native)))]
              (swap! (:sessions ctx) select-keys active-ids)
              (sync-single-session! ctx)))
        sessions (mapv :session (vals (session-states ctx)))]
    (assoc native :sessions sessions :session_count (count sessions)
           :session_id (when (= 1 (count sessions)) (:session_id (first sessions)))
           :active (boolean (seq sessions)) :max_sessions max-sessions
           :memory "embedded-xtdb-2.2" :transport "mcp-stdio"
           :platforms ["macos"] :batch_max_steps 20)))

(defn dispatch! [ctx tool args]
  (case tool
    "computer_capabilities" (capabilities! ctx)
    "computer_windows" (native! ctx :computer_windows args)
    "computer_attach" (attach! ctx args)
    "computer_observe" (let [sid (resolve-session ctx args)
                             options (merge (get-in (session-states ctx) [sid :observation-options])
                                            (select-keys args [:max_nodes :max_depth]))
                             _ (set-session-value! ctx sid :observation-options options)
                             before (last-snapshot ctx sid) after (observe! ctx sid)]
                         (if (and (:delta args) (= (:since_snapshot_id args) (:snapshot_id before)))
                           (delta before after) (assoc after :mode "full")))
    "computer_act" (act! ctx args)
    "computer_batch" (batch! ctx args)
    "computer_screenshot" (let [sid (resolve-session ctx args) snapshot (observe! ctx sid)]
                            (assoc (native! ctx :computer_screenshot (assoc args :session_id sid)) :observation snapshot))
    "computer_detach" (let [sid (resolve-session ctx args)
                            result (native! ctx :computer_detach {:session_id sid})]
                        (swap! (:sessions ctx) dissoc sid)
                        (sync-single-session! ctx)
                        result)
    "computer_memory_search" {:pages (memory/search (store! ctx) args) :historical true :executable false}
    "computer_memory_recall" (or (memory/recall (store! ctx) (:page_id args))
                                 (failure :page-not-found "No saved page has this page_id."))
    "computer_metrics" {:operations @(:metrics ctx) :clock "monotonic"
                        :note "Local elapsed time includes native RPC and synchronous persistence; excludes LLM latency."}
    (failure :unknown-tool "Unknown computer tool.")))

(defn invoke! [ctx tool args]
  ;; Both transports and in-process callers share this serialization boundary.
  (locking ctx
    (tools/validate-call! tool args)
    (let [started (System/nanoTime)]
      (try
        (let [result (dispatch! ctx tool args)]
          (assoc result :elapsed_ms (/ (- (System/nanoTime) started) 1e6)))
        (finally
          (let [ms (/ (- (System/nanoTime) started) 1e6)]
            (swap! (:metrics ctx) update tool
                   (fn [m] {:calls (inc (or (:calls m) 0))
                            :total_ms (+ (or (:total_ms m) 0) ms)
                            :max_ms (max (or (:max_ms m) 0) ms) :last_ms ms}))))))))

(defn close! [ctx]
  (locking ctx
    (doseq [sid (keys (session-states ctx))]
      (try
        ;; Native checks ownership atomically with detach; a separate observe
        ;; would leave a race where a replacement session could be stopped.
        (native! ctx :computer_detach {:session_id sid})
        (catch Exception _ nil)))
    (reset! (:sessions ctx) {})
    (sync-single-session! ctx)
    (when-let [store @(:store ctx)] (.close ^java.io.Closeable store) (reset! (:store ctx) nil))))
