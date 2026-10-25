(ns desktop.audit-test
  (:require [clojure.test :refer [deftest is testing]]
            [desktop.audit :as audit]
            [desktop.agent :as agent]
            [desktop.memory :as memory]
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

(deftest legacy-audit-remains-read-only-and-rejects-incomplete-later-actions
  (let [path (str (Files/createTempDirectory "DeskLoom audit XTDB-" (make-array FileAttribute 0)))]
    (with-open [store (db/open! path)]
      (record-success! store)
      (let [result (audit/audit! store "audit-test")]
        (is (= "first" (:request_id result)))
        (is (= "legacy-verification" (:format result)))
        (is (:historical result)))
      (db/snapshot! store :before (snapshot "before-second" "new"))
      (db/event! store "audit-test" :action-intent
                 {:request_id "second" :snapshot_id "before-second" :node_id "n1" :value "next"})
      (is (thrown? clojure.lang.ExceptionInfo (audit/audit! store "audit-test")))
      (db/event! store "audit-test" :verification-error
                 {:request_id "second" :stage "read-back" :outcome "unknown" :retry false}))
    (with-open [store (db/open! path)]
      (let [failure (:payload (last (db/history store "audit-test")))]
        (is (= "unknown" (:outcome failure)))
        (is (false? (:retry failure))))
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

(deftest generic-audit-recovers-own-durable-receipt-and-keeps-outcomes-distinct
  (let [path (str (Files/createTempDirectory "DeskLoom generic audit XTDB-" (make-array FileAttribute 0)))
        sid "generic-session"
        receipt {:session_id sid :request_id "generic-request" :action "set_value"
                 :based_on "before" :outcome "verified"}
        observation {:session_id sid :snapshot_id "after" :complete true
                     :app {:bundle_id "example.document"} :window {:title "Document"}
                     :nodes [{:id "field" :role "AXTextField" :value "new" :enabled true :settable true}]}]
    (with-open [store (db/open! path)]
      (let [ctx (agent/context)]
        (reset! (:store ctx) store)
        (db/event! store sid :computer-attach {:session_id sid :window_id "window"})
        (db/event! store sid :computer-action-intent
                   {:session_id sid :request_id "generic-request" :action "set_value" :snapshot_id "before"
                    :node_id "field" :value_length 3})
        (agent/once! ctx "generic-request" {:tool "computer_act" :arguments {:session_id sid}}
                     #(do (db/event! store sid :computer-action-result receipt)
                          (assoc receipt :observation (assoc observation :memory (memory/remember! store observation)))))))
    (with-open [store (db/open! path)]
      (let [result (audit/audit! store sid)]
        (is (= "computer-agent" (:format result)))
        (is (= "verified" (:outcome result)))
        (is (true? (:verified result)))
        (is (:observation_recorded result))
        (is (:historical result))
        (is (false? (:executable result))))
      (let [ctx (agent/context)
            dispatched (assoc receipt :request_id "next-request" :action "focus" :outcome "dispatched")]
        (reset! (:store ctx) store)
        (db/event! store sid :computer-action-intent
                   {:session_id sid :request_id "next-request" :action "focus" :snapshot_id "before"})
        (agent/once! ctx "next-request" {:tool "computer_act" :arguments {:session_id sid}}
                     #(do (db/event! store sid :computer-action-result dispatched) dispatched))
        (let [result (audit/audit! store sid)]
          (is (= "dispatched" (:outcome result)))
          (is (false? (:verified result)))
          (is (false? (:observation_recorded result))))
        ;; A later pending intent cannot borrow either earlier receipt.
        (db/event! store sid :computer-action-intent
                   {:session_id sid :request_id "interrupted" :action "click" :snapshot_id "latest"})
        (is (thrown? clojure.lang.ExceptionInfo (audit/audit! store sid)))))))

(deftest generic-audit-rejects-foreign-or-unknown-receipts
  (let [sid "current"
        intent {:session_id sid :request_id "r" :action "focus" :snapshot_id "s"}
        receipt {:session_id sid :request_id "r" :action "focus" :based_on "s" :outcome "dispatched"}
        events [{:kind "computer-attach" :payload {:session_id sid}}
                {:kind "computer-action-intent" :payload intent}
                {:kind "computer-action-result" :payload receipt}]]
    (doseq [[bad-events ledger] [[(assoc-in events [2 :payload :session_id] "foreign") {:state "complete" :result receipt}]
                                 [(assoc-in events [2 :payload :based_on] "other-snapshot") {:state "complete" :result receipt}]
                                 [events {:state "pending"}]
                                 [events {:state "complete" :result (assoc receipt :outcome "unknown")}]
                                 [events {:state "complete" :result (assoc receipt :observation_error {:code "closed"})}]]]
      (with-redefs [db/history (fn [& _] bad-events)
                    agent/request-record (fn [& _] ledger)]
        (is (thrown? clojure.lang.ExceptionInfo (audit/audit! nil sid)))))))
