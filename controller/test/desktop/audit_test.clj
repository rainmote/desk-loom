(ns desktop.audit-test
  (:require [clojure.test :refer [deftest is testing]]
            [desktop.audit :as audit]
            [desktop.core :as desktop]
            [desktop.client :as client]
            [desktop.db :as db])
  (:import [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]))

(defn- snapshot [id text]
  {:session_id "audit-test" :snapshot_id id :complete true
   :nodes [{:id "n1" :role "AXTextArea" :value text :enabled true :settable true}]})

(defn- record-success! [store]
  (db/event! store "audit-test" :session {:session_id "audit-test"})
  (db/snapshot! store :before (snapshot "before" "old"))
  (db/event! store "audit-test" :action-intent
             {:request_id "first" :snapshot_id "before" :node_id "n1" :value "new"})
  (db/event! store "audit-test" :action-result
             {:request_id "first" :result {:request_id "first" :session_id "audit-test"
                                           :based_on "before" :state "dispatched"}})
  (db/snapshot! store :after (snapshot "after" "new"))
  (db/event! store "audit-test" :verification
             {:request_id "first" :passed true :expected "new" :actual "new"
              :before_snapshot "before" :after_snapshot "after"})
  (db/event! store "audit-test" :native-verification
             {:request_id "first" :session_id "audit-test" :verified true}))

(deftest latest-action-must-have-its-own-complete-verification-chain
  ;; Use a real local XTDB, then reopen it to check durable interrupted outcomes.
  ;; Native calls below are stubs; this test never operates TextEdit.
  (let [path (str (Files/createTempDirectory "DeskLoom audit XTDB-" (make-array FileAttribute 0)))
        calls (atom [])]
    (with-open [store (db/open! path)]
      (record-success! store)
      (is (= "first" (:request_id (audit/audit! store "audit-test"))))
      (testing "a new intent cannot reuse the preceding successful verification"
        (db/snapshot! store :before (snapshot "before-second" "new"))
        (db/event! store "audit-test" :action-intent
                   {:request_id "second" :snapshot_id "before-second" :node_id "n1" :value "next"})
        (is (thrown? clojure.lang.ExceptionInfo (audit/audit! store "audit-test")))
        (db/event! store "audit-test" :action-error {:request_id "second" :retry false})
        (is (thrown? clojure.lang.ExceptionInfo (audit/audit! store "audit-test"))))
      (testing "a dispatched write whose read-back throws persists an unknown outcome"
        (with-redefs [desktop/ready-snapshot! (fn [_] (snapshot "before-third" "new"))
                      desktop/verify-value! (fn [_ _ _]
                                             (throw (ex-info "Window closed" {:code "window-not-ready"})))
                      client/rpc! (fn [_ method params]
                                    (swap! calls conj [method params])
                                    (case method
                                      :set_value {:request_id (:request_id params) :session_id "audit-test"
                                                  :based_on "before-third" :state "dispatched"}
                                      :report_verification_error {:phase "验证中断"}))]
          (is (thrown? clojure.lang.ExceptionInfo (desktop/set-text! {:store store :client nil} "next"))))
        (is (= [:set_value :report_verification_error] (mapv first @calls)))
        (is (thrown? clojure.lang.ExceptionInfo (audit/audit! store "audit-test")))))
    (with-open [store (db/open! path)]
      (let [failure (:payload (last (db/history store "audit-test")))]
        (is (= "unknown" (:outcome failure)))
        (is (= "read-back" (:stage failure)))
        (is (false? (:retry failure)))
        (is (= (get-in (first @calls) [1 :request_id]) (:request_id failure))))
      (is (thrown? clojure.lang.ExceptionInfo (audit/audit! store "audit-test"))))))

(deftest audit-rejects-mismatched-action-results-and-interrupted-native-verification
  (let [before (snapshot "before" "old")
        after (snapshot "after" "new")
        events [{:kind "session" :payload {:session_id "audit-test"}}
                {:kind "snapshot" :phase "before" :snapshot "before" :payload before}
                {:kind "action-intent" :payload {:request_id "only" :snapshot_id "before"
                                                 :node_id "n1" :value "new"}}
                {:kind "action-result" :payload {:request_id "only"
                                                 :result {:request_id "only" :session_id "audit-test"
                                                          :based_on "before" :state "dispatched"}}}
                {:kind "snapshot" :phase "after" :snapshot "after" :payload after}
                {:kind "verification" :payload {:request_id "only" :passed true :expected "new" :actual "new"
                                                :before_snapshot "before" :after_snapshot "after"}}
                {:kind "native-verification" :payload {:request_id "only" :session_id "audit-test" :verified true}}]]
    (doseq [bad [(assoc-in events [3 :payload :result :request_id] "unrelated")
                 (assoc-in events [3 :payload :result :based_on] "unrelated")
                 (assoc-in events [2 :payload :value] "different")
                 (assoc-in events [6 :payload :request_id] "unrelated")
                 (subvec events 0 6)
                 (conj events {:kind "verification-error" :payload {:request_id "only" :outcome "unknown"}})]]
      (with-redefs [db/history (fn [_ _] bad)
                    db/text-areas (fn [_ _] [])]
        (is (thrown? clojure.lang.ExceptionInfo (audit/audit! nil "audit-test")))))))
