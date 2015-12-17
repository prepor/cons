(ns condo.ui
  (:require [condo.states :as s]
            [condo.utils :as utils]
            [om.next :as om]
            [sablono.core :refer-macros [html]]))

(defn short-group-name
  [group-name]
  (or (->> group-name (re-matches #"^.*/(.+)$") last) "(no label)"))

(defn instance-state [instance] (-> instance :state first))

(defn group-deploying?
  [{:keys [instances]}]
  (->> instances (some #(= "WaitingNext" (instance-state %)))))

(defn group-warnings
  [{:keys [instances]}]
  (let [all-started? (->> instances (every? #(= "Started" (instance-state %))))
        tags-consistent? (->> instances
                              (map #(->> % :state second :image :tag))
                              (apply =))
        waiting-too-long? (fn [{:keys [state] :as instance}]
                            (and
                              (= "WaitingNext" (instance-state instance))
                              (< (* 5 60)
                                 (->> state last :created_at
                                      utils/seconds-since-ts))))]
    (cond-> []
            (and all-started? (not tags-consistent?))
            (conj "inconsistent image tags")

            (some waiting-too-long? instances)
            (conj "some deployments seem to be taking too long"))))

(defn glyphicon
  [state]
  [:span {:class (str "glyphicon " (get-in s/states [state :glyphicon-class]))
          :data-toggle "tooltip"
          :title (get-in s/states [state :tooltip])}])

(defn verbose-deployment
  [{:keys [image container] :as deployment}]
  (let [{:keys [tag name]} image
        created-at (:created_at deployment)
        stable-at (:stable_at deployment)
        row (fn [label value]
              [:small {:key label}
               [:div {:class "row"}
                [:div {:class "col-sm-2"}
                 [:strong {:class "pull-right"} label]]
                [:div {:class "col-sm-10"} value]]])]
    [:div {:class "panel panel-default panel-deployment"
           :key container}
     [:div {:class "panel-body"}
      (row "Image tag" [:code tag])
      (row "Container" [:code container])
      (row "Created" (utils/timestamp->human created-at))
      (row "Stable" (utils/timestamp->human stable-at))]]))

(defn verbose-instance
  [{:keys [id node address port tags state]}]
  (let [row (fn [label value]
              [:div {:class "row" :key label}
               [:div {:class "col-sm-2"}
                [:strong {:class "pull-right"} label]]
               [:div {:class "col-sm-10"} value]])
        [deployment-state & deployments] state]
    [:li {:key id :class "list-group-item"}
     (row "Address" [:span address])
     (row "Node" [:code node])
     (row "Port" [:span port])
     (row "Condo ID" [:code id])
     (row "Tags" (if (seq tags)
                   (for [t tags]
                     [:span {:key t :class "label label-default"} t])
                   [:span "–"]))
     (row "State" [:code deployment-state " " (glyphicon deployment-state)])
     (for [d deployments]
       (verbose-deployment d))]))

(defn succinct-instance
  [{:keys [id address state]}]
  (let [[deployment-state & deployments] state
        truncate-tag (fn [tag]
                       (if (< 50 (count tag))
                         (str (->> tag (take 50) (apply str)) "…")
                         tag))]
    [:li {:class "list-group-item" :key id}
     [:div {:class "row"}
      [:div {:class "col-sm-2"
             :data-toggle "tooltip"
             :title "Address"}
       address]
      [:div {:class "col-sm-1"} (glyphicon deployment-state)]
      [:div {:class "col-sm-2"}
       (for [d deployments]
         [:div {:class "row" :key (:container d)}
          [:span {:data-toggle "tooltip" :title "Created"}
           (utils/timestamp->human (:created_at d))]])]
      [:div {:class "col-sm-7"}
       (for [d deployments]
         [:div {:class "row" :key (:container d)}
          [:code {:data-toggle "tooltip" :title "Image tag"}
           (truncate-tag (-> d :image :tag))]])]]]))

(defn group-footer
  [instances]
  (let [total (count instances)
        last-deployed (->> instances
                             (map #(->> % :state second :created_at))
                             (apply max) utils/timestamp->human)]
    [:div {:class "panel-footer" :key "footer"}
     [:small
      [:div {:class "row"}
       [:div {:class "col-sm-2" :key "total"}
        (str "Instances: " total)]
       (when (seq last-deployed)
         [:div {:class "col-sm-4" :key "last-ts"}
          (str "Last deployed: " last-deployed)])]]]))

(defn panel-class
  [group]
  (cond
    (every? #(= "Started" (instance-state %)) group) "panel-success"
    (every? #(= "Init" (instance-state %)) group) "panel-default"
    :else "panel-warning"))

(defn group
  [verbose? {:keys [label instances] :as group}]
  (let [warnings (group-warnings group)]
    [:div {:class "panel-group"
           :id (short-group-name label)
           :key (short-group-name label)}
     [:div {:class (str "panel " (panel-class instances)) :key "body"}
      [:div {:class "panel-heading" :key "heading"}
       [:h4 {:class "panel-title" :key "title"}
        (if verbose? label (short-group-name label))]]
      [:ul {:class "list-group" :key "instances"}
       (for [w warnings]
         [:li {:key w :class "list-group-item list-group-item-warning"}
          [:small [:strong "Warning: "] w]])
       (for [i instances]
         (if verbose? (verbose-instance i) (succinct-instance i)))]
      (when verbose? (group-footer instances))]]))

(defn filtered-snapshot
  [condo]
  (let [{:keys [search state-filter snapshot]} (om/props condo)
        re (->> search
                (interpose ".*")
                (apply str)
                (re-pattern))
        by-name #(->> % :label short-group-name (re-find re))
        by-state #(case state-filter
                   :warnings (seq (group-warnings %))
                   :deploying (group-deploying? %)
                   true)]
    (->> snapshot (filter by-name) (filter by-state))))

(defn group-badges
  [group]
  (let [count-by-state (->> group :instances
                            (map instance-state)
                            (frequencies))]
    (->> count-by-state
         (map (fn [[st cnt]]
                [:span {:class (str "badge " (get-in s/states [st :badge-class]))
                        :data-toggle "tooltip"
                        :title (get-in s/states [st :tooltip])
                        :key st}
                 cnt])))))

(defn sidebar
  [condo]
  [:div {:class "hidden-xs hidden-sm col-md-3" :key "sidebar"}
   [:ul {:class "list-group sidebar"}
    (->> (filtered-snapshot condo)
         (map (fn [group]
                (let [label (-> group :label short-group-name)]
                  [:a {:href (str "#" label)
                       :class "list-group-item"
                       :key label}
                   (when (seq (group-warnings group))
                     [:span {:class "glyphicon glyphicon-alert text-danger"
                             :data-toggle "tooltip"
                             :title (str "Group " label " has warnings, consult the "
                                         "panel for details")
                             :key (str label "-warning")}])
                   label
                   (group-badges group)]))))]])

(defn group-name-filter
  [condo]
  [:form {:class "navbar-form"}
   [:input {:type "text"
            :class "form-control group-search"
            :value (:search (om/props condo))
            :placeholder "filter by group name"
            :role "search"
            :on-change (fn [e]
                         (let [input (.. e -target -value)]
                           (om/transact! condo [`(ui/update-search {:search ~input})
                                                :search])))}]])

(defn state-toggler
  [condo]
  (let [state-filter (:state-filter (om/props condo))
        option (fn [st text]
                 [:span
                  (if (= st state-filter)
                    {:class "toggler-active" :key st}
                    {:class "toggler-inactive" :key st
                     :on-click #(om/transact!
                                 condo [`(ui/toggle-state-filter {:state-filter ~st})
                                        :state-filter])})
                  (str text)])]
    [:div {:class "toggler pull-right"}
     (option :deploying "deploying now")
     [:span {:class "navbar-separator" :key "sep-1"} "/"]
     (option :warnings "with warnings")
     [:span {:class "navbar-separator" :key "sep-2"} "/"]
     (option :all "all")]))

(defn verbosity-toggler
  [condo]
  (let [verbose? (:verbose (om/props condo))
        active {:class "toggler-active" :key "active"}
        inactive {:class "toggler-inactive" :key "inactive"
                  :on-click #(om/transact! condo '[(ui/toggle-verbosity) :verbose])}]
    [:div {:class "toggler pull-right"}
     [:span (if verbose? inactive active) "succinct"]
     [:span {:class "navbar-separator" :key "sep"} "/"]
     [:span (if verbose? active inactive) "verbose"]]))

(defn navbar
  [condo]
  [:nav {:class "navbar navbar-default navbar-fixed-top" :key "navbar"}
   [:div {:class "container"}
    [:div {:class "row"}
     [:div {:class "col-md-3" :key "name-filter"}
      (group-name-filter condo)]
     [:div {:class "col-xs-12 col-md-offset-4 col-md-3" :key "state-filter"}
      (state-toggler condo)]
     [:div {:class "col-xs-12 col-md-2" :key "verbosity-filter"}
      (verbosity-toggler condo)]]]])

(defn instances-view
  [condo]
  (let [verbose? (:verbose (om/props condo))]
    [:div {:class "content col-xs-12 col-sm-12 col-md-offset-1 col-md-8"
           :key "instances"}
     (map (partial group verbose?) (filtered-snapshot condo))]))

(def nothing-found
  [:div {:class "container"}
   [:div {:class "filler col-md-offset-3 col-md-6"}
    [:h4 "nothing found"]]])

(def loading
  [:div {:class "filler col-md-offset-3 col-md-6"}
   [:h4 "loading…"]])

(defn content
  [condo]
  [:div {:class "container"}
   (sidebar condo)
   (instances-view condo)
   ])

(defn root
  [condo]
  (html
    (if (= :loading (:state (om/props condo)))
      loading
      [:div
       (navbar condo)
       (if (seq (filtered-snapshot condo))
         (content condo)
         nothing-found)])))
