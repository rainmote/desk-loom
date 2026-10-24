(ns desktop.client
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io])
  (:import [java.net URI]
           [java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers]
           [java.time Duration]))

(defn support-dir []
  (let [base (io/file (System/getProperty "user.home") "Library/Application Support")
        current (io/file base "DeskLoom")
        legacy (io/file base "ComputerUsePrototype")]
    (str (if (or (.isDirectory current) (not (.isDirectory legacy))) current legacy))))

(defn- endpoint-path []
  (let [base (io/file (System/getProperty "user.home") "Library/Application Support")
        current (io/file base "DeskLoom/endpoint.json")
        legacy (io/file base "ComputerUsePrototype/endpoint.json")]
    (str (if (or (.isFile current) (not (.isFile legacy))) current legacy))))

(defn connect
  "Read the native app's private endpoint file. The token is never logged."
  ([] (connect (endpoint-path)))
  ([path]
   (when-not (.isFile (io/file path))
     (throw (ex-info "DeskLoom endpoint missing; run 'dlm open' first."
                     {:code :endpoint-missing :path path})))
   (let [{:keys [port token protocol_version]} (json/read-str (slurp path) :key-fn keyword)]
     (when-not (and (= 1 protocol_version) (integer? port) (< 0 port 65536)
                    (string? token) (seq token))
       (throw (ex-info "Unsupported or malformed native endpoint" {:code :endpoint-invalid})))
     {:uri (URI/create (str "http://127.0.0.1:" port "/rpc"))
      :token token
      :http (-> (HttpClient/newBuilder) (.connectTimeout (Duration/ofSeconds 3)) .build)})))

(defn rpc!
  "One request, no automatic retries. Mutations may have succeeded even on timeout."
  ([client method] (rpc! client method {}))
  ([{:keys [uri token http]} method params]
   (let [request (-> (HttpRequest/newBuilder uri)
                     (.timeout (Duration/ofSeconds 15))
                     (.header "Authorization" (str "Bearer " token))
                     (.header "Content-Type" "application/json")
                     (.POST (HttpRequest$BodyPublishers/ofString
                             (json/write-str {:method (name method) :params params})))
                     .build)
         response (.send ^HttpClient http request (HttpResponse$BodyHandlers/ofString))
         body (json/read-str (.body response) :key-fn keyword)]
     (if (and (= 200 (.statusCode response)) (true? (:ok body)))
       (:result body)
       (throw (ex-info (or (get-in body [:error :message]) "Native request failed")
                       {:code (get-in body [:error :code])
                        :http-status (.statusCode response) :method (name method)}))))))
