(ns desktop.persistence-process
  (:require [clojure.pprint :as pp]
            [desktop.db :as db]))

(def session "independent-jvm-storage-test")
(def payload {:request_id "write-once" :expected "跨 JVM 重启的 XTDB 持久化"
              :actual "跨 JVM 重启的 XTDB 持久化" :passed true})

(defn -main [mode path]
  (try
    (when-not (and path (#{"write" "read"} mode))
      (throw (ex-info "Usage: write|read DB_PATH" {})))
    (with-open [store (db/open! path)]
      (case mode
        "write" (do (db/event! store session :verification payload)
                     (pp/pprint {:mode mode :committed true :path path
                                 :process (.pid (java.lang.ProcessHandle/current))}))
        "read" (let [events (db/history store session)]
                 (when-not (and (= 1 (count events)) (= payload (:payload (first events))))
                   (throw (ex-info "Independent JVM did not restore exact payload" {:events events})))
                 (pp/pprint {:mode mode :recovered true :path path
                             :process (.pid (java.lang.ProcessHandle/current)) :events (count events)}))))
    (catch Throwable t
      (binding [*out* *err*] (println (.getMessage t)) (pp/pprint (ex-data t)))
      (System/exit 1)))
  (shutdown-agents))
