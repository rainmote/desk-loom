(ns desktop.mcp-test
  (:require [clojure.test :refer [deftest is]]
            [desktop.mcp :as mcp]
            [desktop.tools :as tools])
  (:import [java.io BufferedReader StringReader]))

(def initialize {:jsonrpc "2.0" :id 1 :method "initialize"
                 :params {:protocolVersion "2025-11-25" :capabilities {}
                          :clientInfo {:name "test" :version "1"}}})

(deftest negotiation-and-lifecycle
  (let [state (atom {}) calls (atom []) invoke #(swap! calls conj [%1 %2])]
    (is (= -32600 (get-in (mcp/handle! state invoke {:jsonrpc "2.0" :id 0 :method "tools/list"}) [:error :code])))
    (is (= "2025-11-25" (get-in (mcp/handle! state invoke (assoc-in initialize [:params :protocolVersion] "future")) [:result :protocolVersion])))
    (is (nil? (mcp/handle! state invoke {:jsonrpc "2.0" :method "notifications/initialized"})))
    (is (= (count tools/definitions) (count (get-in (mcp/handle! state invoke {:jsonrpc "2.0" :id 2 :method "tools/list"}) [:result :tools]))))
    (is (nil? (mcp/handle! state invoke {:jsonrpc "2.0" :method "tools/call" :params {:name "computer_detach" :arguments {}}})))
    (is (empty? @calls))
    (is (= -32601 (get-in (mcp/handle! state invoke {:jsonrpc "2.0" :id 3 :method "server/discover"}) [:error :code])))
    (doseq [bad [[] nil 3 {:jsonrpc "2.0" :id nil :method "ping"}
                 {:jsonrpc "1.0" :id 1 :method "ping"} {:jsonrpc "2.0" :id 1 :method "ping" :params []}]]
      (is (= -32600 (get-in (mcp/handle! state invoke bad) [:error :code]))))))

(deftest errors-and-images-have-standard-content
  (let [state (atom {:initialized true :version "2025-11-25"})
        call {:jsonrpc "2.0" :id 2 :method "tools/call" :params {:name "computer_screenshot" :arguments {}}}
        error (mcp/handle! state (fn [& _] (throw (ex-info "permission missing" {:code :permission}))) call)
        picture (mcp/handle! state (fn [& _] {:data "aGVsbG8=" :mime_type "image/png" :width 10}) call)]
    (is (true? (get-in error [:result :isError])))
    (is (nil? (:error error)))
    (is (= "image" (get-in picture [:result :content 1 :type])))
    (is (= 10 (get-in picture [:result :structuredContent :width])))
    (is (nil? (get-in picture [:result :structuredContent :data])))
    (is (= -32602 (get-in (mcp/handle! state (fn [& _] (throw (Exception. "must not dispatch")))
                                          (assoc-in call [:params :arguments :max_width] -1)) [:error :code])))))

(deftest strict-input-and-bounds
  (doseq [[name args] [["computer_batch" {:request_id "x" :steps []}]
                       ["computer_batch" {:request_id "x" :steps (vec (repeat 21 {:action "focus"}))}]
                       ["computer_act" {:action "click" :request_id "x" :selector {}}]
                       ["computer_act" {:action "click" :request_id "x" :selector {:xpath "unsafe"}}]
                       ["computer_act" {:action "click" :request_id "x" :x Double/NaN}]
                       ["computer_act" {:action "arbitrary" :request_id "x"}]
                       ["computer_act" {:action "click"}]
                       ["computer_act" {:action "type_text" :snapshot_id "s" :request_id "x" :text (apply str (repeat 4097 "a"))}]
                       ["computer_act" {:action "set_value" :snapshot_id "s" :node_id "n1" :request_id "x" :value (apply str (repeat 34000 "中"))}]
                       ["computer_act" {:action "key" :snapshot_id "s" :request_id "x"}]
                       ["computer_batch" {:request_id "x" :steps [{:action "click"}]}]
                       ["computer_batch" {:session_id "A" :request_id "x" :steps [{:action "focus" :session_id "B"}]}]
                       ["computer_observe" {:session_id ""}]
                       ["computer_detach" {:session_id 1}]
                       ["missing" {}]]]
    (is (thrown? clojure.lang.ExceptionInfo (tools/validate-call! name args))))
  (let [reader (BufferedReader. (StringReader. "abc\ndef\nlast"))]
    (is (= "abc" (mcp/read-message-line reader)))
    (is (= "def" (mcp/read-message-line reader)))
    (is (= "last" (mcp/read-message-line reader)))
    (is (nil? (mcp/read-message-line reader))))
  (with-redefs [mcp/max-line-length 4]
    (let [reader (BufferedReader. (StringReader. "12345\nok\n"))]
      (is (= :desktop.mcp/oversize (mcp/read-message-line reader)))
      (is (= "ok" (mcp/read-message-line reader))))))

(deftest multi-session-schemas-remain-compatible-and-batches-cannot-switch-windows
  (doseq [[name args] [["computer_observe" {}]
                       ["computer_observe" {:session_id "A" :max_nodes 1000}]
                       ["computer_act" {:session_id "A" :action "focus" :snapshot_id "s" :request_id "r"}]
                       ["computer_batch" {:session_id "A" :request_id "b" :steps [{:action "focus"}]}]
                       ["computer_screenshot" {:session_id "A" :max_width 640}]
                       ["computer_detach" {:session_id "A"}]]]
    (is (= args (tools/validate-call! name args))))
  (doseq [name ["computer_observe" "computer_act" "computer_batch" "computer_screenshot" "computer_detach"]]
    (is (= "string" (get-in tools/by-name [name :inputSchema :properties :session_id :type]))))
  (is (nil? (get-in tools/by-name ["computer_batch" :inputSchema :properties :steps :items :properties :session_id]))))
