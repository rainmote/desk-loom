(ns desktop.agent-test
  (:require [clojure.test :refer [deftest is]]
            [desktop.agent :as agent]
            [desktop.db :as db]
            [desktop.memory :as memory])
  (:import [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]))

(def snapshot {:session_id "session" :snapshot_id "fresh" :complete true
               :app {:bundle_id "test.app"} :window {:id "window" :title "Document"}
               :nodes [{:id "n0" :role "AXWindow" :title "Document" :enabled true}
                       {:id "n1" :parent_id "n0" :role "AXTextArea" :value "old" :enabled true :settable true}]})

(deftest delta-always-remaps-fresh-tokens
  (let [after (-> snapshot (assoc :snapshot_id "new")
                  (assoc-in [:nodes 0 :id] "new0") (assoc-in [:nodes 1 :id] "new1")
                  (assoc-in [:nodes 1 :parent_id] "new0"))
        result (agent/delta snapshot after)]
    (is (= ["new0" "new1"] (:node_ids result)))
    (is (= [nil "new0"] (:parent_ids result)))
    (is (= [] (:changed_nodes result)))
    (is (= "fresh" (:base_snapshot_id result)))
    (is (= [1] (:removed_indices (agent/delta snapshot (update after :nodes subvec 0 1)))))))

(deftest selectors-reject-incomplete-and-ambiguous-pages
  (is (= "n1" (:id (agent/select-node snapshot {:role "AXTextArea"})) ))
  (is (thrown? clojure.lang.ExceptionInfo (agent/select-node (assoc snapshot :complete false) {:role "AXTextArea"})))
  (is (thrown? clojure.lang.ExceptionInfo (agent/select-node (update snapshot :nodes conj (last (:nodes snapshot))) {:role "AXTextArea"}))))

(deftest durable-idempotency-survives-reopen-and-blocks-interrupted-requests
  (let [path (str (Files/createTempDirectory "DeskLoom request ledger " (make-array FileAttribute 0)))
        dispatched (atom 0)
        signature {:tool "computer_act" :arguments {:text "private-input"}}]
    (with-open [store (db/open! path)]
      (let [ctx (agent/context)]
        (reset! (:store ctx) store)
        (is (= "dispatched" (:outcome (agent/once! ctx "once" signature #(do (swap! dispatched inc) {:outcome "dispatched"})))) )
        (is (:replayed (agent/once! ctx "once" signature #(swap! dispatched inc))))
        (is (thrown? clojure.lang.ExceptionInfo (agent/once! ctx "once" {:different true} #(swap! dispatched inc))))
        (agent/save-request! store "interrupted" {:signature (agent/signature-hash signature) :state "pending"})
        (is (not (.contains (pr-str (agent/request-record store "once")) "private-input")))))
    (with-open [store (db/open! path)]
      (let [ctx (agent/context)]
        (reset! (:store ctx) store)
        (is (:replayed (agent/once! ctx "once" signature #(swap! dispatched inc))))
        (is (= "unknown" (:outcome (agent/once! ctx "interrupted" signature #(swap! dispatched inc)))))))
    (is (= 1 @dispatched))))

(deftest ledger-stores-content-reference-instead-of-another-page-copy
  (let [result {:outcome "verified" :request_id "r"
                :observation (assoc snapshot :memory {:page_id "p" :version_id "v"})}
        receipt (agent/durable-receipt result)]
    (is (nil? (:observation receipt)))
    (is (= {:page_id "p" :version_id "v" :historical true :executable false}
           (:observation_reference receipt)))
    (is (= "verified" (:outcome receipt)))))

(deftest expanded-observation-limits-persist-for-selector-resolution
  (let [ctx (agent/context) calls (atom [])]
    (reset! (:session ctx) "session")
    (with-redefs [agent/native! (fn [_ method args] (swap! calls conj args) snapshot)
                  agent/store! (constantly :store)
                  memory/remember! (fn [& _] {})]
      (agent/invoke! ctx "computer_observe" {:max_nodes 1000 :max_depth 40})
      (agent/observe! ctx)
      (is (= [{:session_id "session" :max_nodes 1000 :max_depth 40}
              {:session_id "session" :max_nodes 1000 :max_depth 40}] @calls)))))

(deftest dispatch-persists-before-and-after-and-does-not-repeat-on-readback-failure
  (let [ctx (agent/context) log (atom []) calls (atom [])]
    (reset! (:session ctx) "session")
    (reset! (:last-snapshot ctx) snapshot)
    (with-redefs [agent/store! (fn [_] :store)
                  memory/remember! (fn [_ s] (swap! log conj :page) {:page_id "saved"})
                  db/event! (fn [_ _ kind payload] (swap! log conj [kind payload]))
                  agent/native! (fn [_ method params]
                                  (swap! calls conj method)
                                  (case method :computer_act {:outcome "dispatched"}
                                               :computer_observe (throw (ex-info "window closed" {}))))]
      (let [result (agent/perform! ctx {:action "set_value" :snapshot_id "fresh" :node_id "n1" :request_id "r" :value "secret"})]
        (is (= "dispatched" (:outcome result)))
        (is (:observation_error result))
        (is (= [:computer_act :computer_observe] @calls))
        (is (= [:computer-action-intent :computer-action-result] (mapv first @log)))
        (is (nil? (get-in @log [0 1 :value])))
        (is (= 6 (get-in @log [0 1 :value_length])))))))

(deftest batch-keeps-partial-receipts-and-stops
  (let [ctx (agent/context) actions (atom [])]
    (reset! (:session ctx) "session")
    (reset! (:last-snapshot ctx) snapshot)
    (with-redefs [agent/once! (fn [_ _ _ f] (f))
                  agent/observe! (fn [_ _] snapshot)
                  agent/act! (fn [_ args]
                               (swap! actions conj args)
                               (if (= 1 (count @actions)) {:outcome "dispatched"}
                                 (throw (ex-info "changed" {:code :stale-target}))))]
      (let [result (agent/batch! ctx {:request_id "batch" :steps [{:action "focus"} {:action "key" :key "tab"} {:action "click" :x 1 :y 2}]})]
        (is (= "stopped" (:outcome result)))
        (is (= 1 (:completed result)))
        (is (= 2 (count (:steps result))))
        (is (= 2 (count @actions)))))))

(deftest cannot-detach-another-client
  (let [ctx (agent/context) calls (atom [])]
    (with-redefs [agent/native! (fn [_ method args]
                                 (swap! calls conj [method args])
                                 (throw (ex-info "The native session changed." {:code :session-changed})))]
      (is (thrown? clojure.lang.ExceptionInfo (agent/dispatch! ctx "computer_detach" {})))
      (is (empty? @calls))
      (reset! (:session ctx) "mine")
      (is (thrown? clojure.lang.ExceptionInfo (agent/dispatch! ctx "computer_detach" {})))
      (is (= [[:computer_detach {:session_id "mine"}]] @calls))
      (is (= "mine" @(:session ctx))))))

(deftest detach-passes-owned-session-atomically
  (doseq [close? [false true]]
    (let [ctx (agent/context) calls (atom [])]
      (reset! (:session ctx) "mine")
      (reset! (:last-snapshot ctx) snapshot)
      (with-redefs [agent/native! (fn [_ method args]
                                   (swap! calls conj [method args])
                                   {:session_id "mine" :active false :detached true})]
        (if close? (agent/close! ctx) (agent/dispatch! ctx "computer_detach" {}))
        (is (= [[:computer_detach {:session_id "mine"}]] @calls))
        (is (nil? @(:session ctx)))))))

(deftest close-cannot-release-a-replacement-session
  (let [ctx (agent/context) calls (atom [])]
    (reset! (:session ctx) "old-session")
    (with-redefs [agent/native! (fn [_ method args]
                                 (swap! calls conj [method args])
                                 (throw (ex-info "Replacement session must stay active." {:code :session-changed})))]
      (agent/close! ctx)
      (is (= [[:computer_detach {:session_id "old-session"}]] @calls))
      (is (nil? @(:session ctx))))))

(defn with-multiple-windows [f]
  (let [ctx (agent/context) calls (atom []) native-sessions (atom {}) revisions (atom {})
        native (fn [_ method args]
                 (swap! calls conj [method args])
                 (let [sid (:session_id args)]
                   (case method
                     :computer_attach
                     (let [sid (str "session-" (:window_id args))
                           session {:session_id sid :window_id (:window_id args) :active true}]
                       (when (contains? @native-sessions sid)
                         (agent/failure :window-already-attached "Already attached."))
                       (swap! native-sessions assoc sid session)
                       session)
                     :computer_capabilities {:sessions (vec (vals @native-sessions))}
                     :computer_observe
                     (do
                       (when-not (contains? @native-sessions sid)
                         (agent/failure :session-changed "No such session."))
                       (let [revision (get (swap! revisions update sid (fnil inc 0)) sid)
                             token (str sid "/" revision)]
                         (-> snapshot (assoc :session_id sid :snapshot_id token)
                             (assoc-in [:nodes 0 :id] (str token "/0"))
                             (assoc-in [:nodes 1 :id] (str token "/1"))
                             (assoc-in [:nodes 1 :parent_id] (str token "/0")))))
                     :computer_act {:session_id sid :outcome "dispatched"}
                     :computer_screenshot {:session_id sid :data "image"}
                     :computer_detach (do (swap! native-sessions dissoc sid)
                                          {:session_id sid :detached true :active false}))))]
    (with-redefs [agent/native! native
                  agent/store! (constantly :store)
                  memory/remember! (fn [& _] {})
                  db/event! (fn [& _])
                  agent/once! (fn [_ _ _ run] (run))]
      (f ctx calls native-sessions))))

(deftest multiple-attaches-preserve-snapshots-and-per-window-observation-options
  (with-multiple-windows
    (fn [ctx calls _]
      (let [a (agent/invoke! ctx "computer_attach" {:window_id "A"})
            before-a (:observation a)
            b (agent/invoke! ctx "computer_attach" {:window_id "B"})
            before-b (:observation b)]
        (is (= before-a (agent/last-snapshot ctx "session-A")))
        (is (nil? @(:session ctx)))
        (is (nil? @(:last-snapshot ctx)))
        (let [result (agent/invoke! ctx "computer_observe"
                                   {:session_id "session-A" :delta true
                                    :since_snapshot_id (:snapshot_id before-a)
                                    :max_nodes 1000 :max_depth 40})]
          (is (= "delta" (:mode result)))
          (is (= (:snapshot_id before-a) (:base_snapshot_id result))))
        (is (= before-b (agent/last-snapshot ctx "session-B")))
        (agent/invoke! ctx "computer_observe" {:session_id "session-B"})
        (agent/observe! ctx "session-A")
        (is (= [[:computer_observe {:session_id "session-B"}]
                [:computer_observe {:session_id "session-A" :max_nodes 1000 :max_depth 40}]]
               (take-last 2 @calls)))
        (let [state @(:sessions ctx)]
          (is (thrown? clojure.lang.ExceptionInfo
                       (agent/invoke! ctx "computer_attach" {:window_id "A"})))
          (is (= state @(:sessions ctx))))))))

(deftest ambiguous-and-foreign-session-requests-never-reach-native
  (with-multiple-windows
    (fn [ctx calls _]
      (agent/invoke! ctx "computer_attach" {:window_id "A"})
      (agent/invoke! ctx "computer_attach" {:window_id "B"})
      (reset! calls [])
      (doseq [[tool args] [["computer_observe" {}] ["computer_screenshot" {}] ["computer_detach" {}]
                           ["computer_act" {:action "focus" :snapshot_id "ignored" :request_id "r"}]
                           ["computer_batch" {:request_id "r" :steps [{:action "focus"}]}]]]
        (doseq [[params code] [[args :session-required] [(assoc args :session_id "someone-else") :session-changed]]]
          (is (= code (try (agent/invoke! ctx tool params) nil
                          (catch clojure.lang.ExceptionInfo e (:code (ex-data e))))))))
      (is (empty? @calls)))))

(deftest actions-reject-cross-window-tokens-and-resolve-selectors-in-the-chosen-session
  (with-multiple-windows
    (fn [ctx calls _]
      (let [a (:observation (agent/invoke! ctx "computer_attach" {:window_id "A"}))
            b (:observation (agent/invoke! ctx "computer_attach" {:window_id "B"}))]
        (reset! calls [])
        (doseq [args [{:snapshot_id (:snapshot_id a) :node_id (get-in a [:nodes 1 :id])}
                     {:snapshot_id (:snapshot_id b) :node_id (get-in a [:nodes 1 :id])}]]
          (is (thrown? clojure.lang.ExceptionInfo
                       (agent/perform! ctx (merge args {:session_id "session-B" :action "set_value" :value "x" :request_id "r"})))))
        (is (empty? @calls))
        (agent/invoke! ctx "computer_act" {:session_id "session-A" :action "set_value" :value "x"
                                           :request_id "selector" :selector {:role "AXTextArea"}})
        (is (= [:computer_observe :computer_act :computer_observe] (mapv first @calls)))
        (is (every? #(= "session-A" (:session_id (second %))) @calls))
        (is (.startsWith ^String (:node_id (second (second @calls))) "session-A/"))
        (is (= b (agent/last-snapshot ctx "session-B")))))))

(deftest batches-and-screenshots-stay-bound-to-one-window
  (with-multiple-windows
    (fn [ctx calls _]
      (agent/invoke! ctx "computer_attach" {:window_id "A"})
      (let [b (:observation (agent/invoke! ctx "computer_attach" {:window_id "B"}))]
        (reset! calls [])
        (let [result (agent/invoke! ctx "computer_batch"
                                   {:session_id "session-A" :request_id "batch"
                                    :steps [{:action "focus"} {:action "key" :key "tab"}
                                            {:action "set_value" :selector {:role "AXTextArea"} :value "value"}]})]
          (is (= "dispatched" (:outcome result)))
          (is (= 3 (:completed result)))
          (is (= "session-A" (get-in result [:observation :session_id]))))
        (is (every? #(= "session-A" (:session_id (second %))) @calls))
        (is (= b (agent/last-snapshot ctx "session-B")))
        (reset! calls [])
        (agent/invoke! ctx "computer_screenshot" {:session_id "session-B" :max_width 640})
        (is (= [:computer_observe :computer_screenshot] (mapv first @calls)))
        (is (every? #(= "session-B" (:session_id (second %))) @calls))))))

(deftest detach-and-close-release-only-owned-sessions
  (with-multiple-windows
    (fn [ctx calls native-sessions]
      (agent/invoke! ctx "computer_attach" {:window_id "A"})
      (let [b (:observation (agent/invoke! ctx "computer_attach" {:window_id "B"}))]
        (swap! native-sessions assoc "foreign" {:session_id "foreign" :window_id "C"})
        (let [capabilities (agent/invoke! ctx "computer_capabilities" {})]
          (is (= 2 (:session_count capabilities)))
          (is (= #{"session-A" "session-B"} (set (map :session_id (:sessions capabilities))))))
        (agent/invoke! ctx "computer_detach" {:session_id "session-A"})
        (is (= "session-B" @(:session ctx)))
        (is (= b @(:last-snapshot ctx)))
        ;; Omitted session_id remains compatible once only one is owned.
        (agent/invoke! ctx "computer_observe" {})
        (agent/close! ctx)
        (is (= [[:computer_detach {:session_id "session-A"}]
                [:computer_detach {:session_id "session-B"}]]
               (filter #(= :computer_detach (first %)) @calls)))
        (is (= #{"foreign"} (set (keys @native-sessions))))
        (is (empty? @(:sessions ctx)))))))

(deftest capabilities-reconciles-closed-windows-without-adopting-foreign-sessions
  (with-multiple-windows
    (fn [ctx _ native-sessions]
      (agent/invoke! ctx "computer_attach" {:window_id "A"})
      (agent/invoke! ctx "computer_attach" {:window_id "B"})
      (swap! native-sessions dissoc "session-A")
      (swap! native-sessions assoc "foreign" {:session_id "foreign"})
      (let [caps (agent/invoke! ctx "computer_capabilities" {})]
        (is (= 1 (:session_count caps)))
        (is (= "session-B" (:session_id caps)))
        (is (= "session-B" @(:session ctx)))))))

(deftest request-ledger-signatures-include-resolved-session
  (with-multiple-windows
    (fn [ctx _ _]
      (agent/invoke! ctx "computer_attach" {:window_id "A"})
      (agent/invoke! ctx "computer_attach" {:window_id "B"})
      (let [signatures (atom [])]
        (with-redefs [agent/once! (fn [_ _ signature _] (swap! signatures conj signature) {})]
          (agent/act! ctx {:session_id "session-A" :request_id "same" :action "focus"})
          (agent/act! ctx {:session_id "session-B" :request_id "same" :action "focus"})
          (is (not= (agent/signature-hash (first @signatures))
                    (agent/signature-hash (second @signatures)))))))))

(deftest session-limit-does-not-dispatch-or-replace-existing-windows
  (with-multiple-windows
    (fn [ctx calls _]
      (doseq [window (map str (range agent/max-sessions))]
        (agent/invoke! ctx "computer_attach" {:window_id window}))
      (let [states @(:sessions ctx) before @calls]
        (is (= :session-limit
               (try (agent/invoke! ctx "computer_attach" {:window_id "ninth"}) nil
                    (catch clojure.lang.ExceptionInfo e (:code (ex-data e))))))
        (is (= states @(:sessions ctx)))
        (is (= before @calls))))))

(deftest native-failures-retire-only-the-targets-tokens-and-cleanup-continues
  (with-multiple-windows
    (fn [ctx _ _]
      (let [a (:observation (agent/invoke! ctx "computer_attach" {:window_id "A"}))
            b (:observation (agent/invoke! ctx "computer_attach" {:window_id "B"}))
            attempts (atom [])]
        (with-redefs [agent/native! (fn [_ method args]
                                     (swap! attempts conj [method args])
                                     (throw (ex-info "connection lost" {})))]
          (is (thrown? clojure.lang.ExceptionInfo
                       (agent/perform! ctx {:session_id "session-A" :action "focus"
                                            :snapshot_id (:snapshot_id a) :request_id "unknown"})))
          (is (nil? (agent/last-snapshot ctx "session-A")))
          (is (= b (agent/last-snapshot ctx "session-B")))
          (agent/close! ctx)
          (is (= #{"session-A" "session-B"}
                 (set (map (comp :session_id second)
                           (filter #(= :computer_detach (first %)) @attempts)))))
          (is (empty? @(:sessions ctx))))))))

(deftest wrong-session-observations-cannot-replace-cached-tokens
  (with-multiple-windows
    (fn [ctx _ _]
      (let [a (:observation (agent/invoke! ctx "computer_attach" {:window_id "A"}))
            b (:observation (agent/invoke! ctx "computer_attach" {:window_id "B"}))]
        (with-redefs [agent/native! (fn [& _] b)
                      memory/remember! (fn [& _] (throw (Exception. "Do not persist a foreign observation.")))]
          (is (= :session-changed
                 (try (agent/observe! ctx "session-A") nil
                      (catch clojure.lang.ExceptionInfo e (:code (ex-data e))))))
          (is (= a (agent/last-snapshot ctx "session-A")))
          (is (= b (agent/last-snapshot ctx "session-B"))))))))
