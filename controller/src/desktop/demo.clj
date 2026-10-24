(ns desktop.demo
  (:refer-clojure :exclude [run!])
  (:require [clojure.pprint :as pp]
            [desktop.core :as desktop]
            [desktop.db :as db]))

(defn run! []
  (let [controller (desktop/connect!)
        result (try
                 (let [session (desktop/start! controller)
                       text (str "DeskLoom\n"
                                 "Swift AX → Clojure REPL → XTDB 2.2\n"
                                 "已通过无障碍写入并读回验证。\n"
                                 "Session: " (:session_id session) "\n")
                       verified (desktop/set-text! controller text)]
                   (desktop/stop! controller)
                   {:session session :verification verified})
                 (finally (desktop/close! controller)))]
    ;; A new embedded node must replay persisted data, rather than consulting
    ;; the previous node's memory. Verification is part of demo success.
    (with-open [store (db/open!)]
      (let [sid (get-in result [:session :session_id])
            events (db/history store sid)
            saved (some #(when (= "verification" (:kind %)) (:payload %)) events)
            verified (:verification result)]
        (when-not (= verified saved)
          (throw (ex-info "XTDB reopen verification failed" {:code :persistence-failed})))
        (assoc result :persistence {:reopened true :events (count events)
                                    :text-areas (count (db/text-areas store sid))
                                    :path (db/default-path)})))))

(defn -main [& _]
  (try (pp/pprint (run!))
       (catch Throwable t
         (binding [*out* *err*]
           (println (.getMessage t)) (pp/pprint (ex-data t)))
         (System/exit 1)))
  (shutdown-agents))
