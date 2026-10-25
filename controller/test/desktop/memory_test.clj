(ns desktop.memory-test
  (:require [clojure.java.io :as io]
            [clojure.test :refer [deftest is testing]]
            [desktop.db :as db]
            [desktop.memory :as memory]
            [xtdb.api :as xt])
  (:import [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]))

(def fixture
  {:session_id "session-a" :snapshot_id "snapshot-a"
   :app {:bundle_id "example.browser" :pid 17 :name "Browser"}
   :window {:id "window-a" :title "A remembered page" :url "https://example.test/account"}
   :captured_at "2026-10-24T00:00:00Z" :complete true
   :nodes [{:id "window-node" :role "AXWindow" :title "A remembered page"
            :enabled true :settable false :actions []}
           {:id "text-node" :parent_id "window-node" :role "AXTextField" :title "Search"
            :value "你好 XTDB" :enabled true :settable true :actions ["AXConfirm"]}
           {:id "save-node" :parent_id "window-node" :role "AXButton" :title "Save"
            :enabled true :settable false :actions ["AXPress"]}]})

(defn- with-temp-store [f]
  (let [path (str (Files/createTempDirectory "DeskLoom memory 空格-" (make-array FileAttribute 0)))]
    (try (f path)
         (finally (doseq [file (reverse (file-seq (io/file path)))] (io/delete-file file true))))))

(deftest input-bounds-reject-before-any-database-operation
  (with-redefs [xt/q (fn [& _] (throw (AssertionError. "Invalid input reached XTDB")))
                xt/execute-tx (fn [& _] (throw (AssertionError. "Invalid input reached XTDB")))]
    (doseq [snapshot [nil (dissoc fixture :app)
                     (assoc fixture :complete "yes")
                     (assoc fixture :nodes (repeat 5001 (first (:nodes fixture))))
                     (assoc-in fixture [:nodes 1 :value] (apply str (repeat 131073 "x")))
                     (assoc-in fixture [:nodes 1 :value] Double/NaN)
                     (assoc-in fixture [:nodes 1 :enabled] "yes")
                     (assoc-in fixture [:nodes 1 :id] "window-node")
                     (assoc-in fixture [:nodes 1 :actions] [42])]]
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #".+" (memory/remember! {} snapshot))))
    (doseq [options [{:limit 0} {:limit 101} {:limit 1.5} {:limit nil}
                    {:query (apply str (repeat 1025 "x"))} {:bundle_id 4} []]]
      (is (thrown? clojure.lang.ExceptionInfo (memory/search {} options))))
    (is (thrown? clojure.lang.ExceptionInfo (memory/recall {} "")))))

(deftest sql-values-remain-parameters
  (let [seen (atom nil)
        injection "%' OR 1=1 --_"]
    (with-redefs [xt/q (fn [_ query & _] (reset! seen query) [])]
      (is (= [] (memory/search {:node :fake} {:query injection :bundle_id injection :limit 7})))
      (is (not (.contains ^String (first @seen) injection)))
      (is (= [injection "%' or 1=1 --_" 7] (rest @seen))))))

(deftest page-memory-deduplicates-searches-and-survives-reopen
  (with-temp-store
    (fn [path]
      (let [saved-page (atom nil)
            initial-hash (atom nil)]
        (with-open [store (db/open! path)]
          (is (= [] (memory/search store {})))
          (let [first-visit (memory/remember! store fixture)
                changed-handles (-> fixture
                                    (assoc :session_id "session-b" :snapshot_id "snapshot-b"
                                           :captured_at "later")
                                    (assoc-in [:app :pid] 99)
                                    (assoc-in [:window :id] "window-b")
                                    (assoc-in [:nodes 0 :id] "new-root")
                                    (assoc-in [:nodes 1 :id] "new-text")
                                    (assoc-in [:nodes 1 :parent_id] "new-root")
                                    (assoc-in [:nodes 2 :id] "new-save")
                                    (assoc-in [:nodes 2 :parent_id] "new-root")
                                    (assoc-in [:nodes 2 :bounds] {:x 500 :y 200}))
                second-visit (memory/remember! store changed-handles)
                changed-content (assoc-in changed-handles [:nodes 1 :value] "Balance 100%_done")
                third-visit (memory/remember! store changed-content)
                fourth-visit (memory/remember! store changed-content)
                recalled (memory/recall store (:page_id first-visit))]
            (reset! saved-page (:page_id first-visit))
            (reset! initial-hash (:content_hash first-visit))
            (testing "New IDs, time and geometry never create another content version"
              (is (:changed first-visit))
              (is (:new_version first-visit))
              (is (= (:page_id first-visit) (:page_id second-visit) (:page_id third-visit)))
              (is (= (:content_hash first-visit) (:content_hash second-visit)))
              (is (false? (:changed second-visit)))
              (is (false? (:new_version second-visit)))
              (is (:changed third-visit))
              (is (false? (:changed fourth-visit)))
              (is (= 4 (:visit_count recalled)))
              (is (= 2 (:n (first (xt/q (:node store) "SELECT COUNT(*) AS n FROM desktop_page_versions")))))
              (is (= 4 (:n (first (xt/q (:node store) "SELECT COUNT(*) AS n FROM desktop_page_visits"))))))
            (testing "Recall supplies semantic data and explicit historical provenance"
              (is (true? (:historical recalled)))
              (is (false? (:executable recalled)))
              (is (= "untrusted" (:content_trust recalled)))
              (is (= "snapshot-b" (get-in recalled [:observation :historical_snapshot_id])))
              (is (nil? (get-in recalled [:snapshot :snapshot_id])))
              (is (every? #(and (nil? (:id %)) (nil? (:parent_id %)))
                          (get-in recalled [:snapshot :nodes])))
              (is (= 0 (get-in recalled [:snapshot :nodes 1 :parent_index])))
              (is (= "Balance 100%_done" (get-in recalled [:snapshot :nodes 1 :value])))
              (is (every? :requires_fresh_observation (:selectors recalled))))
            (testing "Search is case-insensitive, literal, bounded and app-scoped"
              (is (= [@saved-page] (mapv :page_id (memory/search store {:query "BALANCE"}))))
              (is (= 1 (count (memory/search store {:query "%_"}))))
              (is (= [] (memory/search store {:query "%' OR 1=1 --"})))
              (is (= [] (memory/search store {:bundle_id "other.app"})))
              (is (= 1 (count (memory/search store {:bundle_id "example.browser" :limit 1}))))
              (is (nil? (:snapshot (first (memory/search store {})))))
              (is (nil? (memory/recall store "page-does-not-exist"))))
            (testing "Revisiting old content reuses its immutable version"
              (let [revisited (memory/remember! store fixture)]
                (is (:changed revisited))
                (is (false? (:new_version revisited)))
                (is (= @initial-hash (:content_hash revisited)))
                (is (= 2 (:n (first (xt/q (:node store) "SELECT COUNT(*) AS n FROM desktop_page_versions")))))))
            (testing "Bundle IDs separate apps; URL identity survives title changes"
              (let [other-app (memory/remember! store (assoc-in fixture [:app :bundle_id] "other.app"))
                    renamed (memory/remember! store (assoc-in fixture [:window :title] "New title"))]
                (is (not= @saved-page (:page_id other-app)))
                (is (= @saved-page (:page_id renamed)))
                (is (= 2 (count (memory/search store {}))))
                (is (= 1 (count (memory/search store {:bundle_id "other.app"}))))))))
        (with-open [reopened (db/open! path)]
          (let [recalled (memory/recall reopened @saved-page)]
            (is (= "New title" (:title recalled)))
            (is (= 6 (:visit_count recalled)))
            (is (= "你好 XTDB" (get-in recalled [:snapshot :nodes 1 :value])))
            (is (= 2 (count (memory/search reopened {:query "你好"}))))
            (is (= 7 (:n (first (xt/q (:node reopened) "SELECT COUNT(*) AS n FROM desktop_page_visits")))))))))))

(deftest title-identity-and-ambiguous-semantic-selectors
  (with-temp-store
    (fn [path]
      (with-open [store (db/open! path)]
        (let [snapshot (-> fixture
                           (update :window dissoc :url)
                           (assoc :nodes [{:id "a" :role "AXButton" :title "Save"}
                                          {:id "b" :role "AXButton" :title "Save"}]))
              initial (memory/remember! store snapshot)
              next-page (memory/remember! store (assoc-in snapshot [:window :title] "Another page"))
              recalled (memory/recall store (:page_id initial))]
          (is (not= (:page_id initial) (:page_id next-page)))
          (is (= [{:selector {:role "AXButton" :title "Save"} :matches 2 :ambiguous true
                   :requires_fresh_observation true}]
                 (:selectors recalled))))))))

(deftest webarea-page-identity-and-secure-content-redaction
  (with-temp-store
    (fn [path]
      (with-open [store (db/open! path)]
        (let [snapshot (-> fixture
                           (update :window dissoc :url)
                           (assoc :nodes [{:id "web" :role "AXWebArea" :url "https://example.test/secure"}
                                          {:id "password" :role "AXTextField" :secure true
                                           :value "plaintext-secret-must-never-persist"}
                                          {:id "masked" :role "AXTextField" :value_redacted true
                                           :value "another-secret-must-never-persist"}
                                          {:id "subrole" :role "AXTextField" :subrole "AXSecureTextField"
                                           :value "subrole-secret-must-never-persist"}]))
              initial (memory/remember! store snapshot)
              renamed (memory/remember! store (assoc-in snapshot [:window :title] "Signed in"))
              recalled (memory/recall store (:page_id initial))
              versions (xt/q (:node store) "SELECT * FROM desktop_page_versions")]
          (is (= (:page_id initial) (:page_id renamed)))
          (is (= "https://example.test/secure" (:url recalled)))
          (is (true? (get-in recalled [:snapshot :nodes 1 :secure])))
          (is (every? :value_redacted (rest (get-in recalled [:snapshot :nodes]))))
          (is (every? #(not (contains? % :value)) (rest (get-in recalled [:snapshot :nodes]))))
          (is (not (.contains (pr-str versions) "secret-must-never-persist")))
          (is (= [] (memory/search store {:query "secret-must-never-persist"})))
          (let [conflicting (update snapshot :nodes conj {:id "second-web" :role "AXWebArea"
                                                         :url "https://example.test/other"})
                title-based (memory/remember! store conflicting)
                renamed-title (memory/remember! store (assoc-in conflicting [:window :title] "Another title"))]
            (is (not= (:page_id initial) (:page_id title-based)))
            (is (not= (:page_id title-based) (:page_id renamed-title)))
            (is (= "" (:url (memory/recall store (:page_id title-based)))))))))))
