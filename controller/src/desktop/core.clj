(ns desktop.core
  "Interactive wrappers over the same multi-window service used by MCP and JSONL.
   Every target is explicit; connecting never launches an app or attaches a window."
  (:require [desktop.agent :as agent]
            [desktop.db :as db])
  (:import [java.util UUID]))

(defn connect!
  "Check the native connection and create an independent controller context.
   Options are :endpoint and :db-path; XTDB opens lazily on the first saved visit.
   Always call close! to release this controller's sessions and database."
  ([] (connect! {}))
  ([options]
   (let [controller (agent/context options)]
     (agent/invoke! controller "computer_capabilities" {})
     controller)))

(defn status [controller]
  (agent/invoke! controller "computer_capabilities" {}))

(defn windows
  "List existing windows. Optional filters are :pid and :bundle_id."
  ([controller] (windows controller {}))
  ([controller filters] (agent/invoke! controller "computer_windows" filters)))

(defn attach!
  "Attach an explicitly selected :window_id, optionally checked against :pid or
   :bundle_id. Returns :session_id and :observation; other sessions stay attached."
  [controller target]
  (when-not (and (map? target) (string? (:window_id target)) (seq (:window_id target)))
    (agent/failure :target-required "Choose an explicit window_id from windows before attaching."))
  (agent/invoke! controller "computer_attach" target))

(defn- scoped [session-id options]
  (when-not (and (string? session-id) (seq session-id))
    (agent/failure :session-required "Pass the attached window's session_id explicitly."))
  (when-not (map? options)
    (agent/failure :invalid-arguments "Operation options must be a map."))
  (when (and (contains? options :session_id) (not= session-id (:session_id options)))
    (agent/failure :session-changed "Options cannot override the explicitly selected session_id."))
  (assoc options :session_id session-id))

(defn observe!
  "Read and persist one owned window. Options include :max_nodes/:max_depth and delta settings."
  ([controller session-id] (observe! controller session-id {}))
  ([controller session-id options]
   (agent/invoke! controller "computer_observe" (scoped session-id options))))

(defn- request [options]
  (if (contains? options :request_id) options
    (assoc options :request_id (str (UUID/randomUUID)))))

(defn act!
  "Perform one action, using a fresh snapshot/node pair or unique :selector.
   A request_id is generated when omitted. Unknown outcomes are never retried."
  [controller session-id action]
  (agent/invoke! controller "computer_act" (request (scoped session-id action))))

(defn batch!
  "Execute up to 20 steps within one session, stopping on errors or unknown results.
   Optional options may contain :request_id; steps cannot switch sessions."
  ([controller session-id steps] (batch! controller session-id steps {}))
  ([controller session-id steps options]
   (agent/invoke! controller "computer_batch" (request (assoc (scoped session-id options) :steps steps)))))

(defn screenshot!
  "Capture exactly one attached window; :max_width is optional."
  ([controller session-id] (screenshot! controller session-id {}))
  ([controller session-id options]
   (agent/invoke! controller "computer_screenshot" (scoped session-id options))))

(defn detach!
  "Release only the named owned session. Other clients and windows stay attached."
  [controller session-id]
  (agent/invoke! controller "computer_detach" (scoped session-id {})))

(defn history
  "Read persisted events for a session, including sessions that have detached.
   Returned data is historical; its tokens cannot authorize new actions."
  [controller session-id]
  (scoped session-id {})
  (locking controller
    (db/history (agent/store! controller) session-id)))

(defn close!
  "Release all sessions owned by this controller, then close its embedded database."
  [controller]
  (agent/close! controller))
