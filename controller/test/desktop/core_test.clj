(ns desktop.core-test
  (:require [clojure.test :refer [deftest is]]
            [desktop.core :as desktop]
            [desktop.agent :as agent]
            [desktop.memory :as memory]
            [desktop.db :as db]))

(deftest connection-and-enumeration-do-not-open-storage-or-control-a-window
  (let [calls (atom [])]
    (with-redefs [agent/native! (fn [_ method args] (swap! calls conj [method args])
                                 {:sessions [] :windows [{:window_id "chosen" :pid 12}]})
                  db/open! (fn [& _] (throw (Exception. "Read-only discovery must not open XTDB.")))]
      (let [c (desktop/connect! {:endpoint "/explicit/endpoint" :db-path "/explicit/db"})]
        (is (= "/explicit/endpoint" (get-in c [:options :endpoint])))
        (is (= [{:window_id "chosen" :pid 12}] (:windows (desktop/windows c {:pid 12}))))
        (is (thrown? clojure.lang.ExceptionInfo (desktop/attach! c {:bundle_id "example.app"})))
        (is (thrown? clojure.lang.ExceptionInfo (desktop/attach! c {})))
        (is (= [:computer_capabilities :computer_windows] (mapv first @calls)))
        (desktop/close! c)))))

(deftest repl-workflow-uses-generic-multi-window-service-and-scoped-cleanup
  (let [calls (atom []) native-sessions (atom {}) revisions (atom {})
        native (fn [_ method args]
                 (swap! calls conj [method args])
                 (let [sid (:session_id args)]
                   (case method
                     :computer_capabilities {:sessions (vec (vals @native-sessions))}
                     :computer_windows {:windows [{:window_id "source" :pid 12} {:window_id "destination" :pid 13}]}
                     :computer_attach (let [sid (str "session-" (:window_id args))
                                            session (assoc args :session_id sid)]
                                        (swap! native-sessions assoc sid session) session)
                     :computer_observe (let [n (get (swap! revisions update sid (fnil inc 0)) sid)]
                                         {:session_id sid :snapshot_id (str sid "/" n) :complete true
                                          :nodes [{:id (str sid "/node") :role "AXTextField" :value "old"
                                                   :enabled true :settable true}]})
                     :computer_act (assoc (select-keys args [:session_id :request_id :action]) :outcome "dispatched")
                     :computer_screenshot {:session_id sid :data "png"}
                     :computer_detach (do (swap! native-sessions dissoc sid) {:session_id sid :detached true}))))]
    (with-redefs [agent/native! native agent/store! (constantly :store)
                  memory/remember! (fn [& _] {}) db/event! (fn [& _])
                  agent/once! (fn [_ _ _ run] (run))]
      (let [c (desktop/connect!)
            available (:windows (desktop/windows c))
            a (desktop/attach! c (first available))
            b (desktop/attach! c (second available))
            sid-a (:session_id a) sid-b (:session_id b)]
        (is (= 2 (:session_count (desktop/status c))))
        (is (= sid-a (:session_id (desktop/observe! c sid-a))))
        (desktop/act! c sid-b {:action "set_value" :selector {:role "AXTextField"} :value "copied"})
        (let [action (second (last (filter #(= :computer_act (first %)) @calls)))]
          (is (= sid-b (:session_id action)))
          (is (= "copied" (:value action)))
          (is (string? (:request_id action))))
        (is (= "dispatched" (:outcome (desktop/batch! c sid-a [{:action "focus"}]))))
        (is (= sid-b (:session_id (desktop/screenshot! c sid-b {:max_width 640}))))
        (let [before @calls]
          (is (thrown? clojure.lang.ExceptionInfo (desktop/observe! c nil)))
          (is (thrown? clojure.lang.ExceptionInfo (desktop/observe! c sid-a {:session_id sid-b})))
          (is (thrown? clojure.lang.ExceptionInfo (desktop/detach! c "foreign")))
          (is (= before @calls)))
        (desktop/detach! c sid-a)
        (is (= #{sid-b} (set (keys @native-sessions))))
        (desktop/close! c)
        (is (empty? @native-sessions))
        (is (= [sid-a sid-b] (mapv (comp :session_id second)
                                  (filter #(= :computer_detach (first %)) @calls))))))))
