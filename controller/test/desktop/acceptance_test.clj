(ns desktop.acceptance-test
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [clojure.test :refer [deftest is]]
            [desktop.acceptance :as acceptance]
            [desktop.client :as client]
            [desktop.core :as desktop]
            [desktop.db :as db])
  (:import [java.nio.file Files]))

;; Synthetic orchestration/validation tests, never live desktop evidence.
;; These tests do not connect to the native app or open XTDB.
(def sample-ui
  {:overlayVisible true :statusThumbnailVisible true :previewLive true
   :overlayVisibilityReason "visible" :overlayLevel 0 :overlayIgnoresMouseEvents true
   :overlayCanBecomeKey false :overlayCanBecomeMain false :overlayIsKeyWindow false
   :statusTitle "正在操作 · TextEdit" :primaryScreenMaxY 1080
   :targetFrame {:x 100 :y 200 :width 700 :height 500}
   :overlayFrame {:x 579 :y 841 :width 224 :height 42}})

(defn- temp-root []
  (str (Files/createTempDirectory "acceptance-synthetic-" (make-array java.nio.file.attribute.FileAttribute 0))))

(deftest no-start-or-database-write-until-both-permissions-are-granted
  (doseq [[ax screen] [[false false] [true false] [false true]]]
    (let [calls (atom []) events (atom [])
          failure (with-redefs [client/rpc! (fn [_ method params]
                                             (swap! calls conj [method params])
                                             {:active false :accessibility ax :screen_recording screen})
                                db/event! (fn [& args] (swap! events conj args))]
                    (try
                      (acceptance/run! {:client nil :store nil :session (atom nil)}
                                       {:evidence-root (temp-root)})
                      nil
                      (catch clojure.lang.ExceptionInfo e e)))]
      (is (= :permissions-required (:code (ex-data failure))))
      (is (= [:status] (mapv first @calls)))
      (is (empty? @events))
      (let [result (json/read-str (slurp (io/file (:evidence_dir (ex-data failure)) "result.json")) :key-fn keyword)]
        (is (= "failed" (:outcome result)))
        (is (nil? (:session_id result)))))))

(deftest current-session-is-not-taken-over-or-stopped
  (let [calls (atom [])
        failure (with-redefs [client/rpc! (fn [_ method _]
                                           (swap! calls conj method)
                                           {:active true :accessibility true :screen_recording true})]
                  (try (acceptance/run! {:client nil :session (atom nil)} {:evidence-root (temp-root)})
                       nil
                       (catch clojure.lang.ExceptionInfo e e)))]
    (is (= :session-already-active (:code (ex-data failure))))
    (is (= [:status] @calls))))

(deftest real-ui-state-is-required
  (is (= sample-ui (acceptance/validate-active-ui! sample-ui)))
  (doseq [bad [(assoc sample-ui :overlayVisible false)
               (assoc sample-ui :statusThumbnailVisible false)
               (assoc sample-ui :previewLive false)
               (assoc sample-ui :statusTitle "正在操作 · OtherApp")
               (assoc sample-ui :overlayLevel 3)
               (assoc sample-ui :overlayIgnoresMouseEvents false)
               (assoc sample-ui :overlayCanBecomeKey true)
               (assoc sample-ui :overlayCanBecomeMain true)
               (assoc sample-ui :overlayIsKeyWindow true)
               (dissoc sample-ui :targetFrame)
               (dissoc sample-ui :primaryScreenMaxY)
               (assoc-in sample-ui [:overlayFrame :y] 200)
               (assoc-in sample-ui [:overlayFrame :x] 97)
               (assoc-in sample-ui [:overlayFrame :x] 105)]]
    (is (thrown? clojure.lang.ExceptionInfo (acceptance/validate-active-ui! bad))))
  (let [moved (-> sample-ui
                  (update-in [:targetFrame :x] + 32)
                  (update-in [:targetFrame :y] + 24)
                  (update-in [:overlayFrame :x] + 32)
                  (update-in [:overlayFrame :y] - 24))]
    (is (= {:dx 32 :dy 24 :overlay_dx 32 :overlay_dy -24
            :overlay_follow_status "verified"
            :overlay_visibility_before "visible" :overlay_visibility_after "visible"}
           (acceptance/validate-overlay-follow! sample-ui moved)))
    (is (thrown? clojure.lang.ExceptionInfo (acceptance/validate-overlay-follow! sample-ui sample-ui)))
    (is (thrown? clojure.lang.ExceptionInfo
                 (acceptance/validate-overlay-follow! sample-ui (assoc moved :overlayFrame (:overlayFrame sample-ui))))))
  (let [wider (-> sample-ui
                  (update-in [:targetFrame :width] + 80)
                  (update-in [:overlayFrame :x] + 80))
        followed (acceptance/validate-overlay-follow! sample-ui wider)]
    (is (= wider (acceptance/validate-active-ui! wider)))
    (is (= {:dx 0 :dy 0 :target_width_delta 80 :overlay_dx 80 :overlay_follow_status "verified"}
           (select-keys followed [:dx :dy :target_width_delta :overlay_dx :overlay_follow_status])))
    (is (thrown? clojure.lang.ExceptionInfo
                 (acceptance/validate-active-ui! (assoc wider :overlayFrame (:overlayFrame sample-ui)))))))

(deftest covered-or-off-space-targets-may-hide-the-marker
  (doseq [reason ["target_covered" "target_not_visible"]]
    ;; A hidden panel can have no current frame; its target still needs bounds.
    (let [hidden (-> sample-ui
                     (assoc :overlayVisible false :overlayVisibilityReason reason)
                     (dissoc :overlayFrame))]
      (is (= hidden (acceptance/validate-active-ui! hidden)))
      (doseq [bad [(dissoc hidden :targetFrame)
                   (assoc-in hidden [:targetFrame :width] 0)
                   (assoc-in hidden [:targetFrame :x] Double/NaN)
                   (assoc hidden :previewLive false)]]
        (is (thrown? clojure.lang.ExceptionInfo (acceptance/validate-active-ui! bad))))))
  (doseq [reason [nil "visible" "inactive" "target_unavailable" "window_list_unavailable" "unknown"]]
    (is (thrown? clojure.lang.ExceptionInfo
                 (acceptance/validate-active-ui!
                  (assoc sample-ui :overlayVisible false :overlayVisibilityReason reason)))))
  (is (thrown? clojure.lang.ExceptionInfo
               (acceptance/validate-active-ui! (assoc sample-ui :overlayVisibilityReason "target_covered")))))

(deftest hidden-marker-movement-is-not-reported-as-visible-following
  (let [hidden (assoc sample-ui :overlayVisible false :overlayVisibilityReason "target_covered")
        moved (-> hidden
                  (update-in [:targetFrame :x] + 32)
                  (update-in [:targetFrame :y] + 24))
        result (acceptance/validate-overlay-follow! hidden moved)]
    (is (= [32 24] ((juxt :dx :dy) result)))
    (is (= "not_observed" (:overlay_follow_status result)))
    (is (= "target_covered" (:overlay_visibility_after result)))
    (is (not (contains? result :overlay_dx)))
    (is (thrown? clojure.lang.ExceptionInfo (acceptance/validate-overlay-follow! hidden hidden)))
    (is (= "not_observed" (:overlay_follow_status (acceptance/validate-overlay-follow! sample-ui moved))))
    ;; Becoming visible again must use the new target position, never the
    ;; stale panel frame retained while it was covered.
    (is (thrown? clojure.lang.ExceptionInfo
                 (acceptance/validate-overlay-follow!
                  hidden (assoc moved :overlayVisible true :overlayVisibilityReason "visible"))))))

(deftest visual-evidence-does-not-activate-the-menu
  (let [calls (atom [])
        ui (assoc sample-ui :popoverShown false)
        evidence (with-redefs [client/rpc! (fn [_ method]
                                             (swap! calls conj method)
                                             (case method :render_ui {} :ui_state ui))]
                   (#'acceptance/visual-evidence! {:client nil} (temp-root)))]
    (is (= [:render_ui :ui_state] @calls))
    (is (= ui (:ui evidence)))
    (is (= {} (:rendered_views evidence)))))

(deftest old-frames-and-frozen-preview-are-not-accepted
  (let [hash (apply str (repeat 64 "a"))
        samples (mapv (fn [i] {:preview_sequence i :preview_sha256 hash
                              :preview_captured_at (str "2026-10-23T00:00:0" i "Z")}) [1 2 3])]
    (is (= samples (acceptance/validate-preview-series! samples)))
    (doseq [bad [(take 2 samples)
                 (assoc-in samples [1 :preview_sequence] 1)
                 (assoc-in samples [1 :preview_captured_at] "2026-10-23T00:00:01Z")
                 (assoc-in samples [2 :preview_sha256] "not-a-real-hash")]]
      (is (thrown? clojure.lang.ExceptionInfo (acceptance/validate-preview-series! bad))))))

(deftest cleanup-must-hide-overlay-and-disable-live-indicator
  (let [status {:active false} ui {:overlayVisible false :previewLive false :statusThumbnailVisible false}]
    (is (= {:status status :ui ui} (acceptance/validate-stopped! status ui)))
    (doseq [[s u] [[{:active true} ui]
                   [status (assoc ui :overlayVisible true)]
                   [status (assoc ui :previewLive true)]
                   [status (assoc ui :statusThumbnailVisible true)]
                   [status {}]]]
      (is (thrown? clojure.lang.ExceptionInfo (acceptance/validate-stopped! s u))))))

(deftest an-action-failure-still-stops-and-leaves-store-ownership-with-caller
  (let [calls (atom []) closes (atom 0)
        controller {:client nil :store nil :session (atom nil)}
        failure
        (with-redefs [client/rpc! (fn [_ method _]
                                   (swap! calls conj method)
                                   (case method
                                     :status {:active false :accessibility true :screen_recording true}
                                     :stop {:active false}
                                     :ui_state {:overlayVisible false :previewLive false :statusThumbnailVisible false}))
                      desktop/start! (fn [c]
                                       (let [session {:session_id "synthetic-fixture" :fixture_path "synthetic.txt"}]
                                         (reset! (:session c) session) session))
                      desktop/set-text! (fn [& _] (throw (ex-info "Synthetic write failure" {:code :synthetic-write-failed})))
                      desktop/close! (fn [_] (swap! closes inc))
                      db/event! (fn [& _] nil)]
          (try (acceptance/run! controller {:evidence-root (temp-root)})
               nil
               (catch clojure.lang.ExceptionInfo e e)))]
    (is (= :synthetic-write-failed (:code (ex-data failure))))
    (is (= [:status :stop :status :ui_state] @calls))
    (is (zero? @closes))
    (let [result (json/read-str (slurp (io/file (:evidence_dir (ex-data failure)) "result.json")) :key-fn keyword)]
      (is (= "failed" (:outcome result)))
      (is (false? (get-in result [:stopped :ui :previewLive])))
      (is (false? (get-in result [:stopped :ui :statusThumbnailVisible]))))))
