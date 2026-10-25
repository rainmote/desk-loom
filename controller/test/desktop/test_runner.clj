(ns desktop.test-runner
  (:require [clojure.test :as test]
            desktop.core-test desktop.db-test desktop.audit-test
            desktop.memory-test desktop.agent-test desktop.mcp-test))

(defn -main [& _]
  (let [{:keys [fail error]} (test/run-tests 'desktop.core-test 'desktop.db-test 'desktop.audit-test
                                           'desktop.memory-test 'desktop.agent-test 'desktop.mcp-test)]
    (shutdown-agents)
    (System/exit (if (zero? (+ fail error)) 0 1))))
