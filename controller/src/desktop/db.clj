(ns desktop.db
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [desktop.client :as client]
            [xtdb.api :as xt]
            [xtdb.node :as xtn])
  (:import [java.io Closeable RandomAccessFile]
           [java.nio.channels OverlappingFileLockException]
           [java.time Instant]
           [java.util UUID]))

(defrecord Store [node lock channel file closed]
  Closeable
  (close [_]
    (when (compare-and-set! closed false true)
      (try (.close ^java.lang.AutoCloseable node)
           (finally (.release lock) (.close channel) (.close file))))))

(defn default-path [] (str (client/support-dir) "/xtdb"))

(defn open!
  "Embedded XTDB 2.2 with both transaction log and object storage on local disk.
   One process owns a directory at a time; no database listener is exposed."
  ([] (open! (default-path)))
  ([path]
   (.mkdirs (io/file path))
   (let [file (RandomAccessFile. (io/file path "controller.lock") "rw")
         channel (.getChannel file)
         lock (try (.tryLock channel) (catch OverlappingFileLockException _ nil))]
     (when-not lock
       (.close channel) (.close file)
       (throw (ex-info "XTDB directory is already in use; close the other REPL/demo first."
                       {:code :database-in-use :path path})))
     (try
       (->Store (let [config (xtn/->config
                             {:log [:local {:path (.toPath (io/file path "log"))}]
                              :storage [:local {:path (.toPath (io/file path "storage"))}]
                              :server {:port -1 :read-only-port -1}
                              :memory-cache {:max-size-bytes (* 64 1024 1024)}
                              :compactor {:threads 1}})]
                  ;; v2.2 defaults Flight SQL to an ephemeral TCP listener.
                  ;; Use the typed config to disable it independently of pgwire.
                  (.setFlightSql config nil)
                  (let [node (xtn/start-node config)]
                    (try
                      ;; Reopened logs replay asynchronously. A committed empty
                      ;; transaction is a barrier behind all prior log entries.
                      (xt/execute-tx node [])
                      node
                      (catch Throwable t (.close node) (throw t)))))
                lock channel file (atom false))
       (catch Throwable t (.release lock) (.close channel) (.close file) (throw t))))))

(defn event!
  "Commit a complete event, synchronously. JSON payload keeps exact native field names."
  [store session kind payload]
  (let [id (str (UUID/randomUUID))
        doc {:xt/id id :session session :kind (name kind)
             :at (Instant/now) :payload (json/write-str payload)}]
    (xt/execute-tx (:node store) [[:put-docs :desktop_events doc]])
    id))

(defn snapshot! [store phase snapshot]
  (let [sid (:session_id snapshot)
        snap (:snapshot_id snapshot)
        at (Instant/now)
        event {:xt/id (str (UUID/randomUUID)) :session sid :kind "snapshot"
               :phase (name phase) :snapshot snap :at at :payload (json/write-str snapshot)}
        nodes (mapv (fn [n]
                      {:xt/id (str snap "/" (:id n)) :session sid :snapshot snap
                       :role (:role n) :title (or (:title n) "") :value (or (:value n) "")
                       :settable (true? (:settable n)) :enabled (true? (:enabled n))
                       :token (:id n) :at at :payload (json/write-str n)})
                    (:nodes snapshot))]
    (xt/execute-tx (:node store)
                   (cond-> [[:put-docs :desktop_events event]]
                     (seq nodes) (conj (into [:put-docs :desktop_nodes] nodes))))
    snapshot))

(defn history [store session]
  (mapv #(update % :payload (fn [s] (json/read-str s :key-fn keyword)))
        (xt/q (:node store)
              ["SELECT * FROM desktop_events WHERE \"session\" = ? ORDER BY \"at\"" session])))

(defn text-areas [store session]
  (xt/q (:node store)
        ["SELECT snapshot, token, \"value\", settable FROM desktop_nodes WHERE \"session\" = ? AND \"role\" = 'AXTextArea' ORDER BY \"at\"" session]))

(defn sessions [store]
  (xt/q (:node store)
        "SELECT \"session\", MAX(\"at\") AS latest, COUNT(*) AS events FROM desktop_events GROUP BY \"session\" ORDER BY latest DESC"))
