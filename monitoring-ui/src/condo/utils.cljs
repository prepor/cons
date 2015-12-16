(ns condo.utils
  (:require [goog.date :as date]
            [goog.date.relative :as relative-date])
  (:import [goog.date UtcDateTime]))

(defn timestamp->human
  [ts]
  (relative-date/format (* (int ts) 1000)))

(defn seconds-since-ts
  [ts]
  (let [now-ts (-> (date/DateTime.) (.getTime) (/ 1000))]
    (int (- now-ts ts))))
