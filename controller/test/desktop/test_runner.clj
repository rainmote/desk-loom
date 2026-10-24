(ns desktop.test-runner
  (:require [clojure.test :as test]
            desktop.core-test desktop.db-test desktop.audit-test desktop.acceptance-test))

(defn -main [& _]
  (let [{:keys [fail error]} (test/run-tests 'desktop.core-test 'desktop.db-test 'desktop.audit-test 'desktop.acceptance-test)]
    (shutdown-agents)
    (System/exit (if (zero? (+ fail error)) 0 1))))
