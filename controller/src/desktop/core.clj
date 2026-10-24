(ns desktop.core
  (:require [desktop.client :as client]
            [desktop.db :as db])
  (:import [java.time Instant]
           [java.util UUID]))

(defn connect!
  "Connect to the native app and open local XTDB. Close with close!."
  ([] (connect! {}))
  ([{:keys [endpoint db-path]}]
   (let [c (if endpoint (client/connect endpoint) (client/connect))]
     {:client c :store (db/open! (or db-path (db/default-path))) :session (atom nil)})))

(defn status [controller] (client/rpc! (:client controller) :status))
(defn preview [controller] (client/rpc! (:client controller) :preview))

(defn start! [controller]
  (let [session (try (client/rpc! (:client controller) :start)
                     (catch clojure.lang.ExceptionInfo e
                       (if (= "window-not-ready" (:code (ex-data e)))
                         (status controller) (throw e))))]
    (when-not (and (string? (:session_id session)) (string? (:fixture_path session)))
      (throw (ex-info "Native start response is missing fixture identity" {:code :invalid-session})))
    (reset! (:session controller) session)
    (db/event! (:store controller) (:session_id session) :session session)
    session))

(defn observe! [controller]
  (let [snapshot (client/rpc! (:client controller) :observe)
        session @(:session controller)]
    (when-not (= (:session_id session) (:session_id snapshot))
      (throw (ex-info "Session changed; refusing to use snapshot" {:code :session-changed})))
    snapshot))

(defn unique-text-area
  "Refuse incomplete trees, disabled controls and ambiguous selectors."
  [snapshot]
  (when-not (true? (:complete snapshot))
    (throw (ex-info "Accessibility snapshot is incomplete" {:code :incomplete-snapshot})))
  (let [matches (filter #(and (= "AXTextArea" (:role %))
                             (true? (:settable %)) (true? (:enabled %))) (:nodes snapshot))]
    (when-not (= 1 (count matches))
      (throw (ex-info "Expected exactly one writable TextEdit text area"
                      {:code :ambiguous-target :matches (count matches)})))
    (first matches)))

(def transient-observation-codes
  #{"window_not_found" "not_ready" "fixture_not_ready" "no_window" "target_not_ready"
    "window-not-ready" "window-not-found" "target-not-ready"})

(defn ready-snapshot!
  "Bounded observation-only polling. Never repeats start or a mutation."
  ([controller] (ready-snapshot! controller 15000))
  ([controller timeout-ms]
   (let [deadline (+ (System/nanoTime) (* timeout-ms 1000000))]
     (loop []
       (let [result (try
                      (let [s (observe! controller)] (unique-text-area s) {:snapshot s})
                      (catch clojure.lang.ExceptionInfo e
                        (if (or (transient-observation-codes (:code (ex-data e)))
                                (#{:ambiguous-target :incomplete-snapshot} (:code (ex-data e))))
                          {:error e} (throw e))))]
         (if-let [s (:snapshot result)] s
           (if (< (System/nanoTime) deadline)
             (do (Thread/sleep 200) (recur))
             (throw (ex-info "TextEdit did not become ready within timeout"
                             {:code :ready-timeout} (:error result))))))))))

(defn verify-value!
  "Re-read the actual AX value until exact text matches, with a strict deadline."
  [controller expected timeout-ms]
  (let [deadline (+ (System/nanoTime) (* timeout-ms 1000000))]
    (loop []
      (let [s (observe! controller)
            node (unique-text-area s)]
        (if (or (= expected (:value node)) (>= (System/nanoTime) deadline))
          {:passed (= expected (:value node)) :snapshot s :actual (:value node)}
          (do (Thread/sleep 150) (recur)))))))

(defn- report-verification-error!
  "Preserve an interrupted verification without repeating the desktop action.
   Reporting failures must not hide the original exception."
  [controller sid request-id stage ^Exception error]
  (let [failure {:request_id request-id :stage stage :outcome "unknown" :retry false
                 :message (.getMessage error)
                 :code (str (or (:code (ex-data error)) (.getName (class error))))}]
    (try
      (db/event! (:store controller) sid :verification-error failure)
      (catch Exception logging-error (.addSuppressed error logging-error)))
    (try
      (client/rpc! (:client controller) :report_verification_error
                   (select-keys failure [:request_id :stage :message]))
      (catch Exception reporting-error (.addSuppressed error reporting-error)))))

(defn set-text!
  "Record before + intent, dispatch once using fresh snapshot tokens, then verify.
   Native code independently confines the write to this session's fixture window."
  [controller text]
  (when-not (string? text) (throw (ex-info "Text must be a string" {:code :invalid-text})))
  (let [before (ready-snapshot! controller)
        target (unique-text-area before)
        sid (:session_id before)
        store (:store controller)
        request-id (str (UUID/randomUUID))
        action {:snapshot_id (:snapshot_id before) :node_id (:id target)
                :value text :request_id request-id}]
    (db/snapshot! store :before before)
    (db/event! store sid :action-intent action)
    (let [dispatch (try
                     (client/rpc! (:client controller) :set_value action)
                     (catch Exception e
                       (db/event! store sid :action-error
                                  {:request_id request-id :message (.getMessage e)
                                   :code (str (:code (ex-data e))) :retry false})
                       (throw e)))]
      (let [stage (atom "persist-action-result")
            {:keys [verification native-verification]}
            (try
              (db/event! store sid :action-result {:request_id request-id :result dispatch})
              (reset! stage "read-back")
              (let [{:keys [passed snapshot actual]} (verify-value! controller text 5000)
                    verification {:request_id request-id :passed passed
                                  :expected text :actual actual
                                  :before_snapshot (:snapshot_id before)
                                  :after_snapshot (:snapshot_id snapshot)
                                  :verified_at (str (Instant/now))}]
                (reset! stage "persist-read-back")
                (db/snapshot! store :after snapshot)
                (db/event! store sid :verification verification)
                (reset! stage "native-verification")
                (let [native-verification
                      (client/rpc! (:client controller) :verify
                                   {:success passed :expected_value text :request_id request-id :persisted true})]
                  (when-not (boolean? (:verified native-verification))
                    (throw (ex-info "Native verification response has no boolean result"
                                    {:code :invalid-verification-response})))
                  (reset! stage "persist-native-verification")
                  (db/event! store sid :native-verification native-verification)
                  {:verification verification :native-verification native-verification}))
              (catch Exception error
                (report-verification-error! controller sid request-id @stage error)
                (throw error)))]
        (when-not (true? (:verified native-verification))
          (throw (ex-info "Native verification did not confirm the current TextEdit value"
                          {:code :native-verification-failed :verification native-verification})))
        (when-not (:passed verification)
          (throw (ex-info "AX read-back does not match requested text"
                          {:code :verification-failed :verification verification})))
        verification))))

(defn history [controller] (db/history (:store controller) (:session_id @(:session controller))))

(defn stop! [controller]
  (let [result (client/rpc! (:client controller) :stop)]
    (when-let [sid (:session_id @(:session controller))]
      (db/event! (:store controller) sid :stop result))
    result))

(defn close! [controller] (.close ^java.io.Closeable (:store controller)))
