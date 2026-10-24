(ns desktop.db-test
  (:require [clojure.test :refer [deftest is]]
            [desktop.db :as db])
  (:import [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]))

(deftest local-log-and-storage-survive-reopen
  ;; Mirrors macOS's default "Application Support" path, including spaces;
  ;; XTDB interprets string paths as URIs, so its config must receive Path objects.
  (let [path (str (Files/createTempDirectory "DeskLoom 空格 XTDB-" (make-array FileAttribute 0)))
        session "persistence-self-test"
        snapshot {:session_id session :snapshot_id "snapshot-1" :complete true
                  :window_title "Prototype fixture" :pid 1
                  :nodes [{:id "node-1" :role "AXTextArea" :value "你好 XTDB"
                           :title "" :enabled true :settable true :actions []}]}
        verification {:passed true :expected "你好 XTDB" :actual "你好 XTDB"}]
    (with-open [store (db/open! path)]
      (db/snapshot! store :before snapshot)
      (db/event! store session :action-intent {:request_id "once" :value "你好 XTDB"})
      (db/snapshot! store :after (assoc snapshot :snapshot_id "snapshot-2"))
      (db/event! store session :verification verification)
      (is (= 4 (count (db/history store session))))
      (is (thrown? clojure.lang.ExceptionInfo (db/open! path))))
    (with-open [reopened (db/open! path)]
      (let [events (db/history reopened session)
            saved (:payload (last events))]
        (is (= 4 (count events)))
        (is (= verification saved))
        (is (= ["你好 XTDB" "你好 XTDB"] (mapv :value (db/text-areas reopened session))))
        (is (= session (:session (first (db/sessions reopened)))))
        (println "XTDB 2.2.0 reopened persisted events:" (count events) "directory:" path)))))
