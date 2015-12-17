(ns condo.states)

(def states
  {"Init" {:tooltip "Initialized"
           :badge-class "badge-light"
           :glyphicon-class "glyphicon-flash"}
   "Started" {:tooltip "Started"
              :badge-class "badge-success"
              :glyphicon-class "glyphicon-ok text-success"}
   "Waiting" {:tooltip "Waiting"
              :badge-class "badge-light"
              :glyphicon-class "glyphicon-time text-warning"}
   "WaitingNext" {:tooltip "Waiting for the next container"
                  :badge-class "badge-warning"
                  :glyphicon-class "glyphicon-refresh text-warning"}
   "Stopped" {:tooltip "Stopped"
              :badge-class nil
              :glyphicon-class "glyphicon-off"}})
