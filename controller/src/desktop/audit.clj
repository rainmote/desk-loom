(ns desktop.audit
  "Independent-JVM audit of a completed desktop session; never operates the desktop."
  (:require [clojure.pprint :as pp]
            [desktop.agent :as agent]
            [desktop.db :as db]
            [xtdb.api :as xt]))

(defn- audit-legacy! [store session]
  ;; Pre-0.11 verification records remain readable. This branch only reads the
  ;; historical format; it never invokes the retired native workflow.
  (let [events (db/history store session)
        kinds (set (map :kind events))
        intent-index (last (keep-indexed #(when (= "action-intent" (:kind %2)) %1) events))
        intent (when (some? intent-index) (:payload (nth events intent-index)))
        request-id (:request_id intent)
        following (if (some? intent-index) (subvec (vec events) (inc intent-index)) [])
        request-events (filter #(= request-id (get-in % [:payload :request_id])) following)
        payload-of (fn [kind] (last (keep #(when (= kind (:kind %)) (:payload %)) request-events)))
        dispatch (:result (payload-of "action-result"))
        verified (payload-of "verification")
        native-check (payload-of "native-verification")
        failed (some #(#{"action-error" "verification-error"} (:kind %)) request-events)
        before (some #(when (and (= "before" (:phase %))
                                 (= (:before_snapshot verified) (:snapshot %))) (:payload %)) events)
        after (some #(when (and (= "after" (:phase %))
                                (= (:after_snapshot verified) (:snapshot %))) (:payload %)) events)
        expected (:expected verified)
        after-texts (map :value (filter #(= "AXTextArea" (:role %)) (:nodes after)))
        target (first (filter #(= (:node_id intent) (:id %)) (:nodes before)))
        required #{"session" "snapshot" "action-intent" "action-result" "verification" "native-verification"}]
    (when-not (and (every? kinds required) before after (not failed)
                   (string? request-id) (seq request-id)
                   (= request-id (:request_id dispatch))
                   (= session (:session_id dispatch) (:session_id before) (:session_id after)
                      (:session_id native-check))
                   (= (:snapshot_id intent) (:based_on dispatch) (:before_snapshot verified))
                   (= (:value intent) expected)
                   (true? (:complete before)) (true? (:complete after))
                   (= "AXTextArea" (:role target)) (true? (:enabled target)) (true? (:settable target))
                   (true? (:passed verified)) (string? expected)
                   (true? (:verified native-check))
                   (= (:request_id verified) (:request_id native-check))
                   (= expected (:actual verified)) (= [expected] (vec after-texts))
                   (= (:before_snapshot verified) (:snapshot_id before))
                   (= (:after_snapshot verified) (:snapshot_id after)))
      (throw (ex-info "Persisted session is incomplete or verification does not match AX snapshots"
                      {:session session :request_id request-id :kinds kinds})))
    {:session session :persisted true :format "legacy-verification"
     :request_id request-id
     :events (count events) :snapshots [(:snapshot_id before) (:snapshot_id after)]
     :node-rows (count (db/text-areas store session))
     :verification verified}))

(defn- audit-generic! [store session events]
  (let [intent-index (last (keep-indexed #(when (= "computer-action-intent" (:kind %2)) %1) events))
        intent (when (some? intent-index) (:payload (nth events intent-index)))
        request-id (:request_id intent)
        following (if (some? intent-index) (subvec events (inc intent-index)) [])
        receipt (last (keep #(when (and (= "computer-action-result" (:kind %))
                                       (= request-id (get-in % [:payload :request_id]))) (:payload %)) following))
        record (when request-id (agent/request-record store request-id))
        saved (:result record)
        receipt-fields [:session_id :request_id :action :outcome :based_on]
        reference (:observation_reference saved)]
    (when-not (and (some #(and (= "computer-attach" (:kind %))
                               (= session (get-in % [:payload :session_id]))) events)
                   (string? request-id) (seq request-id)
                   (= session (:session_id intent) (:session_id receipt))
                   (= (:action intent) (:action receipt))
                   (= (:snapshot_id intent) (:based_on receipt))
                   (= "complete" (:state record))
                   (#{"verified" "dispatched"} (:outcome receipt))
                   (not (:is_error saved)) (not (:observation_error saved))
                   (= (select-keys receipt receipt-fields) (select-keys saved receipt-fields)))
      (throw (ex-info "The latest action has no complete matching durable receipt; its outcome is not confirmed."
                      {:code :incomplete-audit :session session :request_id request-id})))
    (when reference
      (when-not (and (true? (:historical reference)) (false? (:executable reference))
                     (seq (xt/q (:node store)
                                ["SELECT version_id FROM desktop_page_versions WHERE version_id = ? AND page_id = ?"
                                 (:version_id reference) (:page_id reference)])))
        (throw (ex-info "The durable observation reference has no matching saved page version."
                        {:code :incomplete-audit :session session :request_id request-id}))))
    {:session session :format "computer-agent" :persisted true :request_id request-id
     :events (count events) :action (:action receipt) :outcome (:outcome receipt)
     :verified (= "verified" (:outcome receipt))
     :observation_recorded (boolean reference) :observation_reference reference}))

(defn audit!
  "Read the latest action's own durable evidence. A dispatched receipt is not
   promoted to verified. Historical legacy records retain their original checks."
  [store session]
  (let [events (db/history store session)
        result (if (some #(#{"computer-attach" "computer-action-intent" "computer-action-result"} (:kind %)) events)
                 (audit-generic! store session events)
                 (audit-legacy! store session))]
    (assoc result :historical true :executable false)))

(defn -main [session & [path]]
  (try
    (when-not session (throw (ex-info "Usage: -m desktop.audit SESSION_ID [DB_PATH]" {})))
    (with-open [store (db/open! (or path (db/default-path)))]
      (pp/pprint (assoc (audit! store session) :independent-process true)))
    (catch Throwable t
      (binding [*out* *err*] (println (.getMessage t)) (pp/pprint (ex-data t)))
      (System/exit 1)))
  (shutdown-agents))
