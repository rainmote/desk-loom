(ns desktop.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [desktop.core :as desktop]
            [desktop.client :as client]
            [desktop.db :as db]))

(deftest selection-fails-closed
  (let [field {:id "fresh/1" :role "AXTextArea" :value "original"
               :enabled true :settable true}
        snapshot {:snapshot_id "fresh" :complete true :nodes [field]}]
    (is (= field (desktop/unique-text-area snapshot)))
    (testing "incomplete, disabled or ambiguous trees cannot authorize a write"
      (doseq [bad [(assoc snapshot :complete false)
                   (assoc snapshot :nodes [])
                   (assoc snapshot :nodes [field (assoc field :id "fresh/2")])
                   (assoc-in snapshot [:nodes 0 :enabled] false)
                   (assoc-in snapshot [:nodes 0 :settable] false)]]
        (is (thrown? clojure.lang.ExceptionInfo (desktop/unique-text-area bad)))))))

(deftest failed-readback-is-recorded-and-reported-without-retrying-the-write
  ;; This tests orchestration only; db-test and clj-test separately use real XTDB.
  (let [snapshot {:session_id "test" :snapshot_id "fresh" :complete true
                  :nodes [{:id "fresh/1" :role "AXTextArea" :value "old"
                           :enabled true :settable true}]}
        calls (atom []) events (atom [])]
    (with-redefs [desktop/ready-snapshot! (fn [_] snapshot)
                  desktop/verify-value! (fn [_ _ _] {:passed false :actual "old" :snapshot snapshot})
                  db/snapshot! (fn [_ _ s] s)
                  db/event! (fn [_ _ kind payload] (swap! events conj [kind payload]))
                  client/rpc! (fn [_ method params]
                                (swap! calls conj [method params])
                                (case method :set_value {:state "unknown"}
                                             :verify {:verified false}))]
      (is (thrown? clojure.lang.ExceptionInfo (desktop/set-text! {:store nil :client nil} "new")))
      (is (= [:set_value :verify] (mapv first @calls)))
      (is (false? (get-in (last @calls) [1 :success])))
      (is (some #(and (= :verification (first %)) (false? (get-in % [1 :passed]))) @events))
      (is (not-any? #(= :verification-error (first %)) @events)))))

(deftest verification-interruption-is-recorded-once-without-repeating-a-write
  (doseq [stage ["read-back" "native-verification"]]
    (testing stage
      (let [snapshot {:session_id "test" :snapshot_id "fresh" :complete true
                      :nodes [{:id "fresh/1" :role "AXTextArea" :value "old"
                               :enabled true :settable true}]}
            calls (atom []) events (atom [])
            failure (ex-info "Target disappeared" {:code "window-not-ready"})
            reporting-failure (ex-info "UI unavailable" {})]
        (with-redefs [desktop/ready-snapshot! (fn [_] snapshot)
                      desktop/verify-value! (fn [_ _ _]
                                             (if (= stage "read-back") (throw failure)
                                               {:passed true :actual "new" :snapshot snapshot}))
                      db/snapshot! (fn [_ _ s] s)
                      db/event! (fn [_ _ kind payload] (swap! events conj [kind payload]))
                      client/rpc! (fn [_ method params]
                                    (swap! calls conj [method params])
                                    (case method
                                      :set_value {:state "dispatched"}
                                      :verify (throw failure)
                                      :report_verification_error (throw reporting-failure)))]
          (is (identical? failure (try (desktop/set-text! {:store nil :client nil} "new")
                                       (catch Exception e e))))
          (is (= (if (= stage "read-back") [:set_value :report_verification_error]
                     [:set_value :verify :report_verification_error])
                 (mapv first @calls)))
          (let [errors (filter #(= :verification-error (first %)) @events)
                payload (second (first errors))
                request-id (get-in (first @calls) [1 :request_id])]
            (is (= 1 (count errors)))
            (is (= {:request_id request-id :stage stage :outcome "unknown" :retry false
                    :message "Target disappeared" :code "window-not-ready"} payload))
            (is (= (select-keys payload [:request_id :stage :message])
                   (second (last @calls))))
            (is (not-any? #(= :native-verification (first %)) @events)))
          (is (= [reporting-failure] (vec (.getSuppressed failure)))))))))

(deftest missing-native-verification-result-is-not-success
  (let [snapshot {:session_id "test" :snapshot_id "fresh" :complete true
                  :nodes [{:id "fresh/1" :role "AXTextArea" :value "old"
                           :enabled true :settable true}]}
        events (atom [])]
    (with-redefs [desktop/ready-snapshot! (fn [_] snapshot)
                  desktop/verify-value! (fn [_ _ _] {:passed true :actual "new" :snapshot snapshot})
                  db/snapshot! (fn [_ _ s] s)
                  db/event! (fn [_ _ kind payload] (swap! events conj [kind payload]))
                  client/rpc! (fn [_ _ _] {})]
      (is (= :invalid-verification-response
             (:code (ex-data (try (desktop/set-text! {:store nil :client nil} "new")
                                 (catch Exception e e))))))
      (is (= "unknown" (get-in (last @events) [1 :outcome]))))))
