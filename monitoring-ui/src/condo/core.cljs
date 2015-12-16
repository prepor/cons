(ns condo.core
  (:require-macros [cljs.core.async.macros :refer [go go-loop]])
  (:require [cljs-http.client :as http]
            [cljs.core.async :as a :refer [<!]]
            [condo.ui :as ui]
            [goog.dom :as gdom]
            [om.next :as om :refer-macros [defui]]))

(enable-console-print!)

(defn instance-group
  [instance]
  (let [state (:state instance)]
    (case (first state)
      "Init" "Initializing"
      "Waiting" (let [[_ d] state] (get-in d [:image :name]))
      "WaitingNext" (let [[_ current next] state] (get-in current [:image :name]))
      "Started" (let [[_ d] state] (get-in d [:image :name]))
      "Stopped" "Stopping")))

(defn with-group
  [instance]
  (assoc instance :group (instance-group instance)))

(defn as-group
  [[g instances]]
  {:label g
   :instances (map #(dissoc % :group) instances)})

(defn read
  [{:keys [state]} key _]
  (when-let [v (get @state key)]
    {:value v}))

(defn mutate
  [{:keys [state]} key params]
  (cond
    (= key 'ui/update-search) {:value {:keys [:search]}
                               :action #(swap! state assoc :search (:search params))}
    (= key 'ui/toggle-verbosity) {:value {:keys [:verbose]}
                                  :action #(swap! state update-in [:verbose] not)}
    (= key 'ui/toggle-state-filter) {:value {:keys [:state-filter]}
                                     :action #(swap! state assoc :state-filter
                                                     (:state-filter params))}))

(defui Condo
  static om/IQuery
  (query [_]
    [:state :snapshot :search :verbose :state-filter])
  Object
  (render [this]
    (ui/root this)))

(defonce app-state
  (atom {:state :loading
         :snapshot []
         :search nil
         :verbose false
         :state-filter :all}))

(def reconciler
  (om/reconciler {:state app-state
                  :parser (om/parser {:read read :mutate mutate})}))

(om/add-root! reconciler Condo (gdom/getElement "main"))

(defn start-receiver
  []
  (go-loop []
    (let [response (<! (http/get "/v1/snapshot"))]
      (if (= 200 (:status response))
        (let [data (->> (:body response)
                        (vals)
                        (map with-group)
                        (group-by :group)
                        (map as-group))]
          (swap! app-state assoc
                 :state :ok
                 :snapshot data))
        (swap! app-state assoc :state :error))
      (<! (a/timeout 3000))
      (recur))))

(start-receiver)
