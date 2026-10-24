(ns desktop.acceptance
  "Live TextEdit acceptance from an existing REPL/controller. Never requests permissions."
  (:refer-clojure :exclude [run!])
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.walk :as walk]
            [desktop.client :as client]
            [desktop.core :as desktop]
            [desktop.db :as db])
  (:import [java.nio.file Files]
           [java.security MessageDigest]
           [java.time Instant]
           [java.time.temporal TemporalAccessor]
           [java.util UUID]))

(defn- demand! [condition code message data]
  (when-not condition (throw (ex-info message (assoc data :code code)))))

(defn require-permissions! [status]
  (demand! (and (true? (:accessibility status)) (true? (:screen_recording status)))
           :permissions-required "Live acceptance requires both Accessibility and Screen Recording; no session was started."
           {:permissions (select-keys status [:accessibility :screen_recording])})
  status)

(defn- near? [a b]
  (and (number? a) (number? b) (<= (abs (- (double a) (double b))) 1.0)))

(defn- finite-number? [value]
  (and (number? value) (Double/isFinite (double value))))

(defn- valid-frame? [frame]
  (and (every? #(finite-number? (get frame %)) [:x :y :width :height])
       (pos? (:width frame)) (pos? (:height frame))))

(defn validate-active-ui! [ui]
  (demand! (and (true? (:statusThumbnailVisible ui))
                (true? (:previewLive ui)) (str/includes? (or (:statusTitle ui) "") "TextEdit"))
           :active-ui-mismatch "The controlled app name and live menu thumbnail must be visible." {:ui ui})
  (demand! (and (= 0 (:overlayLevel ui)) (true? (:overlayIgnoresMouseEvents ui))
                (false? (:overlayCanBecomeKey ui)) (false? (:overlayCanBecomeMain ui))
                (false? (:overlayIsKeyWindow ui)))
           :overlay-interaction-mismatch "The overlay must stay at normal window level without taking mouse or keyboard focus." {:ui ui})
  (let [target (:targetFrame ui) overlay (:overlayFrame ui)
        visible (:overlayVisible ui) reason (:overlayVisibilityReason ui)]
    (demand! (valid-frame? target) :missing-target-frame
             "The active session must retain valid target window bounds, including while covered." {:ui ui})
    (demand! (or (and (true? visible) (= "visible" reason))
                  (and (false? visible) (#{"target_covered" "target_not_visible"} reason)))
             :overlay-visibility-mismatch "The overlay must be visible or explicitly hidden because its target is covered or off-screen." {:ui ui})
    ;; A hidden panel retains its previous frame. It is not evidence of where
    ;; a visible marker would be drawn after the target moves.
    (when visible
      (demand! (and (valid-frame? overlay) (finite-number? (:primaryScreenMaxY ui))
                    (near? (:x overlay) (+ (:x target) (:width target) (- (:width overlay)) 3))
                    (near? (:y overlay) (+ (- (:primaryScreenMaxY ui) (:y target) (:height overlay)) 3)))
               :overlay-position-mismatch "The visible overlay is not attached to the target's upper-right corner." {:ui ui})))
  ui)

(defn- validate-target-bounds! [ui bounds]
  (demand! (every? #(near? (get bounds %) (get-in ui [:targetFrame %])) [:x :y :width :height])
           :target-frame-mismatch "The UI target bounds do not match the current AX window bounds." {:ui ui :bounds bounds})
  ui)

(defn validate-preview-series! [samples]
  (demand! (>= (count samples) 3) :insufficient-preview-samples
           "At least three distinct live preview frames are required." {:samples samples})
  (doseq [sample samples]
    (demand! (and (pos-int? (:preview_sequence sample))
                  (string? (:preview_captured_at sample))
                  (re-matches #"[0-9a-f]{64}" (or (:preview_sha256 sample) "")))
             :invalid-preview-sample "Preview metadata is incomplete." {:sample sample}))
  (let [times (mapv #(Instant/parse (:preview_captured_at %)) samples)]
    (demand! (and (apply < (map :preview_sequence samples))
                  (every? (fn [[a b]] (.isBefore ^Instant a b)) (partition 2 1 times)))
             :stale-preview-series "Preview sequence numbers and capture times must strictly increase." {:samples samples}))
  samples)

(defn validate-stopped! [status ui]
  (demand! (and (false? (:active status)) (false? (:overlayVisible ui))
                (false? (:previewLive ui)) (false? (:statusThumbnailVisible ui)))
           :stop-not-confirmed "Stop did not disable the session, overlay, live preview and menu thumbnail." {:status status :ui ui})
  {:status status :ui ui})

(defn- await-check! [read-state validate timeout-ms]
  (let [deadline (+ (System/nanoTime) (* timeout-ms 1000000))]
    (loop []
      ;; Only retry validation of observed state, never the mutation that led
      ;; to it. Transport and native RPC failures still propagate immediately.
      (let [state (read-state)
            result (try {:value (validate state)}
                        (catch clojure.lang.ExceptionInfo e {:error e}))]
        (if-let [e (:error result)]
          (if (< (System/nanoTime) deadline)
            (do (Thread/sleep 100) (recur))
            (throw e))
          (:value result))))))

(defn- json-text [data]
  (json/write-str (walk/postwalk #(if (instance? TemporalAccessor %) (str %) %) data)))

(defn- write-json! [dir name data]
  (let [file (io/file dir name)]
    (spit file (str (json-text data) "\n"))
    (.getAbsolutePath file)))

(defn- sha256 [bytes]
  (apply str (map #(format "%02x" (bit-and 0xff %)) (.digest (MessageDigest/getInstance "SHA-256") bytes))))

(defn- save-preview! [dir stage status]
  ;; preview.png is atomically replaced by the native capture timer. Check the
  ;; copied bytes against the RPC hash; a race is retried only by re-observing.
  (when-let [path (:preview_path status)]
    (let [file (io/file path)]
      (when (.isFile file)
        (let [bytes (Files/readAllBytes (.toPath file))]
          (when (= (:preview_sha256 status) (sha256 bytes))
            (let [name (str "preview-" (name stage) "-" (:preview_sequence status) ".png")
                  destination (io/file dir name)]
              (with-open [output (io/output-stream destination)] (.write output bytes))
              (assoc status :evidence_png (.getAbsolutePath destination)
                            :copied_sha256 (sha256 bytes)))))))))

(defn- preview-samples! [controller dir stage timeout-ms]
  (let [deadline (+ (System/nanoTime) (* timeout-ms 1000000))
        sid (:session_id @(:session controller))]
    (loop [samples []]
      ;; Space frames across capture cycles, not merely distinct RPC calls.
      (Thread/sleep 1100)
      (let [status (desktop/preview controller)
            previous (peek samples)
            candidate (when (and (= sid (:session_id status)) (true? (:active status))
                                  (integer? (:preview_sequence status))
                                  (pos? (:preview_sequence status))
                                  (:preview_captured_at status)
                                  (or (nil? previous)
                                      (and (> (:preview_sequence status) (:preview_sequence previous))
                                           (.isAfter (Instant/parse (:preview_captured_at status))
                                                     (Instant/parse (:preview_captured_at previous))))))
                        (save-preview! dir stage status))
            next-samples (cond-> samples candidate (conj candidate))]
        (cond
          (= 3 (count next-samples)) (validate-preview-series! next-samples)
          (< (System/nanoTime) deadline) (recur next-samples)
          :else (throw (ex-info "Timed out obtaining three verifiable live preview frames."
                               {:code :preview-timeout :stage stage :samples next-samples})))))))

(defn- ui-state! [controller]
  (client/rpc! (:client controller) :ui_state))

(defn- window-bounds [snapshot]
  (let [windows (filter #(and (= "AXWindow" (:role %)) (nil? (:parent_id %))) (:nodes snapshot))
        bounds (or (:window_bounds snapshot) (:bounds (first windows)))]
    (demand! (and (= 1 (count windows))
                  (every? number? (map #(get bounds %) [:x :y :width :height])))
             :missing-window-bounds "The fixture snapshot must contain one root AXWindow with bounds." {})
    bounds))

(defn- move-destination [bounds ui]
  (let [{:keys [x y width height]} bounds
        screen (some (fn [s]
                       (when (and (<= (:x s) x) (<= (:y s) y)
                                  (<= (+ x width) (+ (:x s) (:width s)))
                                  (<= (+ y height) (+ (:y s) (:height s)))) s))
                     (:visibleScreenBounds ui))]
    (demand! screen :fixture-outside-visible-screen
             "The fixture must fit inside a visible screen before the move/restore check." {:bounds bounds :screens (:visibleScreenBounds ui)})
    (let [shift (fn [p lo hi]
                  (let [forward (min hi (+ p 32))]
                    (if (> (abs (- forward p)) 1) forward (max lo (- p 32)))))
          new-x (shift x (:x screen) (- (+ (:x screen) (:width screen)) width))
          new-y (shift y (:y screen) (- (+ (:y screen) (:height screen)) height))]
      (demand! (or (> (abs (- new-x x)) 1) (> (abs (- new-y y)) 1))
               :fixture-has-no-movement-space "The fixture window fills its visible screen; leave room for a small move." {:bounds bounds :screen screen})
      {:x new-x :y new-y})))

(defn- move! [controller x y]
  (let [snapshot (desktop/ready-snapshot! controller)
        sid (:session_id snapshot)
        params {:snapshot_id (:snapshot_id snapshot) :x x :y y :request_id (str (UUID/randomUUID))}]
    (db/snapshot! (:store controller) :move-before snapshot)
    (db/event! (:store controller) sid :move-intent params)
    ;; Deliberately one dispatch. Timeout means outcome unknown, never retry.
    (let [result (client/rpc! (:client controller) :move_window params)]
      (db/event! (:store controller) sid :move-result result)
      result)))

(defn validate-overlay-follow! [before after]
  (validate-active-ui! before)
  (validate-active-ui! after)
  (let [dx (- (get-in after [:targetFrame :x]) (get-in before [:targetFrame :x]))
        dy (- (get-in after [:targetFrame :y]) (get-in before [:targetFrame :y]))
        width-delta (- (get-in after [:targetFrame :width]) (get-in before [:targetFrame :width]))
        report (cond-> {:dx dx :dy dy
                        :overlay_visibility_before (:overlayVisibilityReason before)
                        :overlay_visibility_after (:overlayVisibilityReason after)}
                 (not (zero? width-delta)) (assoc :target_width_delta width-delta))]
    (demand! (or (> (abs dx) 1) (> (abs dy) 1) (> (abs width-delta) 1))
             :target-did-not-move "The target window bounds did not change." {:before before :after after})
    (if (and (:overlayVisible before) (:overlayVisible after))
      (let [overlay-dx (- (get-in after [:overlayFrame :x]) (get-in before [:overlayFrame :x]))
            overlay-dy (- (get-in after [:overlayFrame :y]) (get-in before [:overlayFrame :y]))
            overlay-width-delta (- (get-in after [:overlayFrame :width]) (get-in before [:overlayFrame :width]))]
        (demand! (and (near? (- (+ dx width-delta) overlay-width-delta) overlay-dx)
                      (near? (- dy) overlay-dy))
                 :overlay-did-not-follow "The visible overlay did not follow the fixture window movement." {:before before :after after})
        (assoc report :overlay_follow_status "verified" :overlay_dx overlay-dx :overlay_dy overlay-dy))
      (assoc report :overlay_follow_status "not_observed"
                    :overlay_follow_reason "The marker was hidden in at least one sample; only target movement was verified."))))

(defn- move-and-restore! [controller dir]
  (let [original (window-bounds (desktop/ready-snapshot! controller))
        before (await-check! #(ui-state! controller) validate-active-ui! 2000)
        _ (validate-target-bounds! before original)
        destination (move-destination original before)
        report (atom {:original_bounds original :before before})]
    (try
      (swap! report assoc :move_result (move! controller (:x destination) (:y destination)))
      (desktop/preview controller)
      (let [{:keys [snapshot ui delta]}
            (await-check!
             #(hash-map :snapshot (desktop/observe! controller) :ui (ui-state! controller))
             (fn [{:keys [snapshot ui] :as state}]
               (let [bounds (window-bounds snapshot)]
                 (demand! (every? #(near? (get destination %) (get bounds %)) [:x :y])
                          :move-position-mismatch "Waiting for the fixture's requested AX position." {:bounds bounds :destination destination})
                 (validate-target-bounds! ui bounds)
                 (assoc state :delta (validate-overlay-follow! before ui)))) 2500)]
        (swap! report assoc :moved_snapshot snapshot :after ui :delta delta))
      (finally
        ;; Observe again even if the move timed out: restoring the original
        ;; position is a separate, explicitly intended action, not a retry.
        (try
          (swap! report assoc :restore_result (move! controller (:x original) (:y original)))
          (desktop/preview controller)
          (let [{:keys [snapshot ui]}
                (await-check!
                 #(hash-map :snapshot (desktop/observe! controller) :ui (ui-state! controller))
                 (fn [{:keys [snapshot ui] :as state}]
                   (let [restored (window-bounds snapshot)]
                     (demand! (every? #(near? (get original %) (get restored %)) [:x :y :width :height])
                              :restore-position-mismatch "The fixture window did not return to its original position." {:original original :restored restored})
                     (validate-target-bounds! ui restored)
                     (validate-active-ui! ui)
                     state)) 2500)]
            (swap! report assoc :restored_snapshot snapshot :restored_ui ui))
          (finally (write-json! dir "window-movement.json" @report)))))
    @report))

(defn- visual-evidence! [controller dir]
  (let [paths (client/rpc! (:client controller) :render_ui)
        ui (ui-state! controller)]
    {:ui ui
     :rendered_views
     (into {} (for [[view path] paths]
                (let [output (io/file dir (str "ui-" (name view) ".png"))]
                  (io/copy (io/file path) output)
                  [view (.getAbsolutePath output)])))}))

(defn- require-persisted! [controller verifications]
  (let [events (desktop/history controller)
        persisted (keep #(when (= "verification" (:kind %)) (:payload %)) events)
        nodes (db/text-areas (:store controller) (:session_id @(:session controller)))]
    (doseq [verification verifications]
      (demand! (and (true? (:passed verification)) (some #{verification} persisted)
                    (some #(and (= (:after_snapshot verification) (:snapshot %))
                                (= (:expected verification) (:value %))) nodes))
               :xtdb-readback-mismatch "XTDB query did not recover the verified text and its AX snapshot." {:verification verification}))
    {:events events :text_areas nodes}))

(defonce ^:private run-lock (Object.))

(defn run!
  "Operate a NEW native TextEdit fixture, verify A/B AX values, XTDB, live
   screenshots and overlay movement, then stop. Requires an existing connected
   controller; the caller owns closing XTDB. Never grants or requests TCC.
   Use only one REPL operation at a time while this synchronous run is active."
  ([controller] (run! controller {}))
  ([controller {:keys [evidence-root preview-timeout-ms]
                :or {evidence-root "../evidence" preview-timeout-ms 20000}}]
   (locking run-lock
     (let [started-at (str (Instant/now))
           attempt (str "attempt-" (UUID/randomUUID))
           dir (atom nil)
           transcript (atom [])
           summary (atom {:schema_version 1 :started_at started-at :outcome "running"
                          :repl "existing-controller" :llm false})
           failure (atom nil)
           start-attempted? (atom false)
           original-rpc client/rpc!
           record! (fn [entry]
                     (swap! transcript conj entry)
                     (when @dir (spit (io/file @dir "rpc.jsonl") (str (json-text entry) "\n") :append true)))
           open-evidence! (fn [id]
                            (demand! (boolean (re-matches #"[A-Za-z0-9_-]{1,100}" id))
                                     :invalid-session-id "Refusing unsafe evidence directory name." {})
                            (let [folder (.getCanonicalFile (io/file evidence-root id))]
                              (demand! (not (.exists folder)) :evidence-exists "Evidence directory already exists; refusing to overwrite." {:path (str folder)})
                              (.mkdirs folder)
                              (reset! dir folder)
                              (spit (io/file folder "rpc.jsonl")
                                    (apply str (map #(str (json-text %) "\n") @transcript)))
                              folder))
           rpc (fn rpc
                 ([c method] (rpc c method {}))
                 ([c method params]
                  (let [request {:method (name method) :params params :requested_at (str (Instant/now))}]
                    (try
                      (let [result (original-rpc c method params)]
                        (record! (assoc request :received_at (str (Instant/now)) :result result)) result)
                      (catch Throwable t
                        (record! (assoc request :received_at (str (Instant/now))
                                        :error {:message (.getMessage t) :data (ex-data t)}))
                        (throw t))))))]
       (with-redefs [client/rpc! rpc]
         (try
           (let [preflight (desktop/status controller)]
             (swap! summary assoc :preflight preflight)
             (require-permissions! preflight)
             (demand! (false? (:active preflight)) :session-already-active
                      "Stop the existing native session before starting acceptance; it will not be taken over." {})
             (reset! start-attempted? true)
             (let [session (desktop/start! controller)
                   sid (:session_id session)
                   folder (open-evidence! sid)
                   text-a (str "阶段 A：从 Clojure REPL 操作 TextEdit。\nSwift 无障碍读取与写入 → XTDB 本地历史。\n会话：" sid "\n")
                   text-b (str "阶段 B：中文、换行与画面更新均须真实验证。\n同一个 REPL、同一个 TextEdit 测试文档。\n会话：" sid "\n")]
               (swap! summary assoc :session_id sid :session session)
               (let [a (desktop/set-text! controller text-a)
                     frames-a (preview-samples! controller folder :a preview-timeout-ms)
                     ui-a (await-check! #(ui-state! controller) validate-active-ui! 2000)
                     b (desktop/set-text! controller text-b)
                     frames-b (preview-samples! controller folder :b preview-timeout-ms)
                     ui-b (await-check! #(ui-state! controller) validate-active-ui! 2000)]
                 (validate-preview-series! (into frames-a frames-b))
                 (demand! (not= (:preview_sha256 (peek frames-a)) (:preview_sha256 (peek frames-b)))
                          :preview-did-not-change "The last stage A and stage B image hashes are identical." {})
                 (write-json! folder "text-verifications.json" {:a a :b b})
                 (write-json! folder "preview-samples.json" {:a frames-a :b frames-b})
                 (write-json! folder "active-ui.json" {:a ui-a :b ui-b})
                 (swap! summary assoc :verifications {:a a :b b}
                        :preview_sample_count (+ (count frames-a) (count frames-b)) :preview_hash_changed true)
                 (swap! summary assoc :movement (move-and-restore! controller folder))
                 (swap! summary assoc :visuals (visual-evidence! controller folder))
                 (write-json! folder "xtdb-readback.json" (require-persisted! controller [a b])))))
           (catch Throwable t (reset! failure t))
           (finally
             (when @start-attempted?
               (try
                 (let [stop-result (desktop/stop! controller)
                       stopped (await-check! #(hash-map :status (desktop/status controller) :ui (ui-state! controller))
                                             #(validate-stopped! (:status %) (:ui %)) 2000)]
                   (swap! summary assoc :stop_result stop-result :stopped stopped))
                 (catch Throwable t
                   (swap! summary assoc :cleanup_error {:message (.getMessage t) :data (ex-data t)})
                   (when-not @failure (reset! failure t))))))))
       (when-not @dir (open-evidence! attempt))
       (swap! summary assoc :finished_at (str (Instant/now)) :evidence_dir (str @dir)
              :outcome (if @failure "failed" "passed"))
       (when-let [t @failure]
         (swap! summary assoc :error {:message (.getMessage ^Throwable t) :data (ex-data t)}))
       (write-json! @dir "result.json" @summary)
       (if-let [t @failure]
         (throw (ex-info (.getMessage ^Throwable t)
                         (assoc (ex-data t) :evidence_dir (str @dir) :outcome "failed") t))
         @summary)))))
