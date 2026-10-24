(ns desktop.audit
  "Independent-JVM audit of a completed desktop session; never operates the desktop."
  (:require [clojure.pprint :as pp]
            [desktop.db :as db]))

(defn audit! [store session]
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
    {:session session :persisted true :independent-process true
     :request_id request-id
     :events (count events) :snapshots [(:snapshot_id before) (:snapshot_id after)]
     :node-rows (count (db/text-areas store session))
     :verification verified}))

(defn -main [session & [path]]
  (try
    (when-not session (throw (ex-info "Usage: -m desktop.audit SESSION_ID [DB_PATH]" {})))
    (with-open [store (db/open! (or path (db/default-path)))] (pp/pprint (audit! store session)))
    (catch Throwable t
      (binding [*out* *err*] (println (.getMessage t)) (pp/pprint (ex-data t)))
      (System/exit 1)))
  (shutdown-agents))
