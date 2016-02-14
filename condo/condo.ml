open Core.Std

open Cmdliner

module A = Async.Std

let start endpoints docker_config consul_config advertiser_config envs =
  Gc.tune ~max_overhead:0 ~space_overhead:10 ();
  Random.self_init ();
  (* FIXME host of deployer should be customizable *)
  System.start ~endpoints:endpoints ~docker_config ~consul_config ~advertiser_config ~envs
  |> A.don't_wait_for;
  (* 30 min? it should be configurable or we should excplicit about it in
     documentation *)
  let at_shutdown _s =
    A.Shutdown.shutdown ~force:(A.after (Time.Span.of_min 30.0)) 0 in
  A.Signal.handle A.Signal.terminating ~f:at_shutdown;
  never_returns (A.Scheduler.go ())

let endpoints =
  let doc = "Source of spec. Like consul:///services/test.json" in
  let endpoints =
    Arg.(non_empty & pos_all string [] & info [] ~doc ~docv:"ENDPOINT") in
  let uri endpoints = List.map endpoints Uri.of_string in
  Term.(const uri $ endpoints)

let info =
  let doc = "Good daddy for docker containers" in
  Term.info "condo" ~version:[%getenv "VERSION"] ~doc

let debug =
  let doc = "Debug logs" in
  Arg.(value & flag & info ["d"; "debug"] ~doc)

let setup_log' is_debug =
  let level = if is_debug then `Debug else `Info in
  Async.Std.Log.Global.set_output [Async.Std.Log.Output.stdout ()];
  Async.Std.Log.Global.set_level level;
  ()

let setup_log =
  Term.(const setup_log' $ debug)

let docker =
  let endpoint =
    let doc = "Set ups docker API endpoint" in
    let env = Arg.env_var "DOCKER" ~doc in
    Arg.(value & opt string "tcp://0.0.0.0:2376" & info ["docker"] ~env ~doc) in
  let auth_file =
    let doc = "JSON file with auth config for private registries. In the same format as ~/.docker/config.json" in
    let env = Arg.env_var "DOCKER_AUTH" ~doc in
    Arg.(value & opt (some string) None & info ["docker-auth"] ~env ~doc ~docv:"FILE_PATH") in
  let docker' endpoint auth_file =
    { System.docker_endpoint = endpoint;
      docker_auth_file = auth_file } in
  Term.(const docker' $ endpoint $ auth_file)

let consul =
  let endpoint =
    let doc = "Set ups Consul API endpoint" in
    let env = Arg.env_var "CONSUL" ~doc in
    Arg.(value & opt string "tcp://0.0.0.0:8500" & info ["consul"] ~env ~doc) in
  let consul' endpoint = { System.consul_endpoint = endpoint } in
  Term.(const consul' $ endpoint)

let advertise =
  let is_start =
    let doc = "Advertise itself as consul service and store state in KV" in
    Arg.(value & flag & info ["a"; "advertise"] ~doc ~docv:"PORT") in
  let tags =
    let doc = "List of tags with condo will advertise itself" in
    Arg.(value & opt (list string) [] & info ["tag"] ~doc ~docv:"TAG") in
  let prefix =
    let doc = "KV's prefix in which condo will stores it's state if advertising" in
    Arg.(value & opt string "condo" & info ["prefix"] ~doc ~docv:"PREFIX") in
  let advertise' is_start tags prefix =
    (match is_start with
     | true ->
       Some { System.advertise_tags = tags; advertise_prefix = prefix }
     | false -> None)
  in
  Term.(const advertise' $ is_start $ tags $ prefix)

let envs =
  let doc = "Environment variables which will be added to every spec" in
  Arg.(value & opt_all (pair ~sep:'=' string string) [] & info ["env"] ~doc ~docv:"ENV")

let condo_t = Term.(const start $ endpoints $ docker $ consul $ advertise $ envs $ setup_log)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0
