(defproject condo "0.1.0-SNAPSHOT"
  :description "Condo Monitoring"
  :url "http://condoapp.com"
  :license {:name "MIT License"
            :url "http://opensource.org/licenses/mit-license.php"}
  :min-lein-version "2.5.3"

  :dependencies [[org.clojure/clojure "1.7.0"]
                 [org.clojure/clojurescript "1.7.170"]
                 [org.omcljs/om "1.0.0-alpha22" :exclusions [cljsjs/react]]
                 [cljsjs/react-with-addons "0.14.3-0"]
                 [cljs-http "0.1.38"]
                 [com.andrewmcveigh/cljs-time "0.3.14"]
                 [cljsjs/react "0.14.3-0"]
                 [cljsjs/react-dom "0.14.3-1"]
                 [cljsjs/react-dom-server "0.14.3-0"]
                 [sablono "0.5.1"]
                 [figwheel-sidecar "0.5.0-SNAPSHOT"]]

  :plugins [[lein-figwheel "0.5.0-2"]
            [lein-cljsbuild "1.1.0"]]

  :clean-targets ^{:protect false} [:target-path "out" "resources/public/static/cljs"]

  :cljsbuild {:builds [{:id "dev"
                        :source-paths ["src"]
                        :figwheel true
                        :compiler {:main "condo.core"
                                   :asset-path "static/cljs/out"
                                   :output-to  "resources/public/static/cljs/main.js"
                                   :output-dir "resources/public/static/cljs/out"
                                   :source-map true}}
                       {:id "prod"
                        :source-paths ["src"]
                        :compiler {:main "condo.core"
                                   :optimizations :advanced
                                   :asset-path "static/cljs/out"
                                   :output-to  "out/cljs/main.js"
                                   :output-dir "out/cljs/out"}}]})
