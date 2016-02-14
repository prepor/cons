open Core.Std
open Async.Std

module Edn = struct
  include Edn
  include Utils.Edn
end

type event = NewSpec of Edn.t
           | EnvironmentUpdated
           | Stable
           | NotStable
           | TryAgain of Edn.t
           | Down
           | Stop [@@deriving sexp_of]

type t = {
  name : string;
  docker : Docker.t;
  consul : Consul.t;
  events : event Pipe.Writer.t;
  advertiser : Advertiser.t option;
  envs : (string * string) list;
  mutable try_again : Clock.Event.t_unit option;
}

let merge_envs_to_spec spec envs =
  let envs_to_assoc envs =
    List.map envs (fun {Spec.Env.name; value} -> (name, value)) in
  let assoc_to_envs l = List.map l (fun (name,value) -> {Spec.Env.name; value}) in
  let open Spec in
  { spec with envs = Utils.Assoc.merge (envs_to_assoc spec.envs) envs
                     (* we sort here for stable merge. we compare specs to
                        decide are they same or not, so it's important *)
                     |> List.sort ~cmp:(fun (k1, _) (k2, _) -> String.compare k1 k2)
                     |> assoc_to_envs }

module Watchers = struct
  type t = (unit -> unit Deferred.t) list

  let replace (v : Edn.t) values =
    let rec f = function
      | `Tag (Some "condo", "watcher", `String key) ->
        List.Assoc.find_exn values key
      | `Assoc xs -> `Assoc (List.map xs (fun (v1, v2) -> ((f v1), (f v2))))
      | `List xs -> `List (List.map xs f)
      | `Set xs -> `Set (List.map xs f)
      | `Vector xs -> `Vector (List.map xs f)
      | other -> other in
    f v

  let find t (v : Edn.t) =
    let rec find acc = function
      | `Tag ((Some "condo"), "watcher", (`String v)) ->
        v::acc
      | `Tag ((Some "condo"), "watcher", v) ->
        L.error "[%s] Bad formed watcher: %s" t.name (Edn.to_string v);
        acc
      | `Assoc ((v1, v2)::xs) ->
        find [] v1 @ find [] v2 @ find [] (`Assoc xs) @ acc
      | `Set (v::xs) | `List (v::xs) | `Vector (v::xs) -> find [] v @ List.concat_map xs (find []) @ acc
      | other -> acc in
    find [] v

  let start_watcher t key =
    let parse value = Result.try_with (fun () -> Edn.from_string value) |> function
      | Ok value -> Ok value
      | Error exn ->
        Error (Failure (sprintf "Can't parse value of watcher %s: %s" key (Exn.to_string exn))) in
    let (consul_watcher, stopper) = Consul.key t.consul key in
    let value = Pipe.read consul_watcher >>| function
      | `Eof -> assert false
      | `Ok v ->
        Pipe.transfer consul_watcher t.events ~f:(fun v ->
            L.info "[%s] New watcher (%s) value: %s" t.name key v;
            EnvironmentUpdated) |> don't_wait_for;
        Result.map (parse v) (fun v -> (key, v)) in
    (stopper, value)

  let stop t =
    Deferred.List.iter ~how:`Parallel t ~f:(fun f -> f ()) |> don't_wait_for

  let apply t edn =
    let keys = find t edn in
    let watchers = List.map keys (start_watcher t) in
    let stoppers = List.map watchers fst in
    let values = List.map watchers snd in
    with_timeout (Time.Span.of_int_sec 10) (Deferred.List.all values) >>= function
    | `Timeout ->
      stop stoppers;
      Error (Failure "Timeout while waiting watchers") |> return
    | `Result l ->
      Result.all l |> (function
          | Error exn ->
            stop stoppers;
            Error (Exn.Reraised ("Error in watcher", exn)) |> return
          | Ok values -> Ok (stoppers, (replace edn values)) |> return)

end

module Discoveries = struct
  type t = (unit -> unit Deferred.t) list

  let format_pair (host, port) = sprintf "%s:%i" host port

  let format_discovery service discoveries =
    sprintf "%s -> %s" service (String.concat ~sep:"," (List.map discoveries format_pair))

  let discovery_to_env' spec v =
    let open Spec in
    let mk_env v = (spec.Discovery.env, v) in
    match (v, spec.Discovery.multiple) with
    | (v, true) -> List.map v ~f: format_pair
                   (* we sort here for stable merge. we compare specs to
                      decide are they same or not, so it's important *)
                   |> List.sort ~cmp:String.compare
                   |> String.concat ~sep:","
                   |> mk_env |> Option.some
    | (x::xs, false) -> format_pair x |> mk_env |> Option.some
    | ([], false) -> None

  let discovery_to_env spec v =
    Result.of_option (discovery_to_env' spec v)
      ~error:(Utils.failure "Can't resolve dependency %s" spec.Spec.Discovery.service)

  let start_discovery t spec =
    let {Spec.Discovery.tag; service; watch} = spec in
    let (consul_watcher, stopper) = Consul.discovery t.consul ?tag:tag (Consul.Service.of_string service) in
    let value = Pipe.read consul_watcher >>| function
      | `Eof -> assert false
      | `Ok v ->
        (if watch then
           Pipe.transfer consul_watcher t.events ~f:(fun discoveries ->
               L.info "[%s] New discovery: %s" t.name (format_discovery service discoveries);
               EnvironmentUpdated) |> don't_wait_for
         else
           L.info "[%s] Discovery %s won't be watched after initial resolvement" t.name service);
        discovery_to_env spec v in
    (stopper, value)

  let stop t =
    Deferred.List.iter ~how:`Parallel t ~f:(fun f -> f ()) |> don't_wait_for
    
  let apply t spec =
    let discoveries = List.map spec.Spec.discoveries (start_discovery t) in
    let stoppers = List.map discoveries fst in
    let values = List.map discoveries snd in
    with_timeout (Time.Span.of_int_sec 10) (Deferred.List.all values) >>= function
    | `Timeout ->
      stop stoppers;
      Error (Failure "Timeout while waiting discoveries") |> return
    | `Result l ->
      Result.all l |> (function
          | Error exn ->
            stop stoppers;
            Error (Exn.Reraised ("Error with discovery", exn)) |> return
          | Ok values -> Ok (stoppers, merge_envs_to_spec spec values) |> return)


end

type deploy = {
  spec : Spec.t;
  raw_spec : Edn.t;
  container : Docker.container;
  services : (Spec.Service.t * Consul.Service.id) list;
  stop_checks : (unit -> unit);
  stop_supervisor : (unit -> unit) option;
  created_at : float;
  stable_at : float option;
  watchers : Watchers.t;
  discoveries : Discoveries.t;
}

let deploy_to_yojson deploy =
  `Assoc [("image", Spec.Image.to_yojson deploy.spec.Spec.image);
          ("container", `String (Docker.container_to_string deploy.container));
          ("created_at", `Float deploy.created_at);
          ("stable_at", match deploy.stable_at with
            | Some v -> `Float v
            | None -> `Null)]

let deploy_of_yojson _ = assert false

type state = Init
           | Waiting of deploy
           | WaitingNext of deploy * deploy
           | Started of deploy
           | Stopped [@@deriving yojson]

let stable_watcher t container services =
  let wait_for = List.map services (fun (spec, id) ->
      (id, Spec.Service.(Time.Span.of_int_sec spec.check.Spec.Check.timeout))) in
  let (waiter, closer) = Consul.wait_for_passing t.consul wait_for in
  let stable_watcher' = waiter >>= function
    | `Closed -> return ()
    | `Pass -> Pipe.write t.events Stable
    | `Error err ->
      L.error "[%s] Error while stable watching: %s" t.name (Exn.to_string err);
      Pipe.write t.events NotStable in
  stable_watcher' |> don't_wait_for;
  closer

let spec_label spec =
  Spec.Image.(sprintf "%s:%s" spec.Spec.image.name spec.Spec.image.tag)

let deregister_services t deploy =
  let f s = Consul.deregister_service t.consul (snd s) in
  List.map deploy.services f |> Deferred.all >>| fun _ -> ()

let partition_result l = List.partition_map l ~f: (function
    | Ok v -> `Fst v
    | Error v -> `Snd v)

let register_services t spec container ports =
  let container' = Docker.container_to_string container in
  let suffix = Stringext.take container' 12 in
  let register_service service_spec =
    let port = List.Assoc.find_exn ports service_spec.Spec.Service.port in
    let template_vars = [("host", (Docker.host t.docker));
                         ("port", string_of_int port);
                         ("container", container')] in
    Consul.register_service t.consul ~id_suffix:suffix service_spec template_vars port >>|?
    fun service_id -> (service_spec, service_id) in
  List.map spec.Spec.services register_service |> Deferred.all >>|
  partition_result >>| fun (res, errors) ->
  let service_ids = List.map res snd in
  let close_registered () =
    List.map service_ids (Consul.deregister_service t.consul) |> Deferred.all >>| fun _ -> () in
  match errors with
  | x::_ -> close_registered () |> don't_wait_for; Error x
  | _ -> Ok res

let now () = let open Core.Time in now () |> to_epoch

let prepare_device mapping (volume, device) =
  let {Spec.Volume.from} = volume in
  let {Spec.Volume.path; prepare_command; mount_command; wait} = device in
  L.debug "Wait for device %s (volume %s)" path from;
  let rec wait_for_device () =
    Sys.file_exists path >>= function
    | `Yes -> return ()
    | _ -> (after (Time.Span.of_ms 100.0) >>= fun () ->
            wait_for_device ()) in
  let check_mount () =
    List.find mapping ~f:(fun (path', from') -> path = path' && from = from')
    |> Option.is_some in
  let run' d = d >>| Utils.err_result_to_exn >>|? fun _ -> () in
  let mkdir () =
    Process.run ~prog:"mkdir" ~args:["-p"; from] () |> run'  in
  let try_to_prepare () =
    match prepare_command with
    | Some (prog :: args) -> Process.run ~prog ~args () |> run'
    | Some [] -> Error (Utils.failure "Invalid prepare_command for %s device" path) |> return
    | None -> Ok () |> return in
  let try_to_mount () =
    match mount_command with
    | Some (prog :: args) -> Process.run ~prog:prog ~args:args () |> run'
    | Some [] -> Error (Utils.failure "Invalid mount_command for %s device" path) |> return
    | None -> Process.run ~prog:"mount" ~args:[path; from] () |> run' in
  let mount_it () =
    if check_mount () then return (Ok ())
    else
      mkdir () >>=? fun () ->
      try_to_mount () >>= (function
          | Ok () -> return (Ok ())
          (* ignore prepare errors *)
          | Error _ -> try_to_prepare () >>= fun _ -> try_to_mount ()) in
  with_timeout (Time.Span.of_int_sec wait) (wait_for_device ()) >>| (function
      | `Result v -> Ok v
      | `Timeout -> let err = sprintf "Timeout while waiting for device %s (volume %s)" path from in
        Error (Failure err)) >>=?
  mount_it

let prepare_devices spec =
  let with_devices = spec.Spec.volumes
                     |> List.filter_map ~f:(fun v ->
                         match v.Spec.Volume.device with
                         | Some device -> Some (v, device)
                         | None -> None) in
  if List.is_empty with_devices then return (Ok ())
  else
    Utils.Mount.mapping () >>=? fun mapping ->
    List.map ~f:(prepare_device mapping) with_devices
    |> Utils.Deferred.all_or_error >>|? fun _ -> ()

let validate_stop_strategy spec =
  let open Spec in
  match spec.stop with
  | Before -> true
  | After _ ->
    let has_host_port_services = spec.services |> List.exists ~f: (fun s ->
        match s.Service.host_port with None -> false | Some _ -> true) in
    not has_host_port_services

let parse_spec t edn =
  Watchers.apply t edn
  >>=? fun (watchers, edn') ->
  let yojson = edn' |> Edn.Json.to_json in
  Spec.of_yojson (yojson :> Yojson.Safe.json) |> function
  | `Ok spec when validate_stop_strategy spec ->
    Ok (spec, watchers) |> return
  | `Ok _ ->
    Watchers.stop watchers;
    Error (Failure "Invalid spec: stop strategy \"After\" is not allowed for services with \"host_port\"")
    |> return
  | `Error err ->
    Watchers.stop watchers;
    Error (Failure ("Error in parsing spec: " ^ err)) |> return

(* We just ignore fails in stop action *)
let stop t ?(timeout=0) deploy =
  deploy.stop_checks ();
  Discoveries.stop deploy.discoveries;
  Watchers.stop deploy.watchers;
  deregister_services t deploy >>= fun () ->
  after (Time.Span.of_int_sec timeout) >>= fun () ->
  L.info "[%s] Stop container %s"
    t.name (Docker.container_to_string deploy.container);
  (match deploy.stop_supervisor with
   | Some s -> s (); return ()
   | None -> return ()) >>= fun () ->
  Docker.stop t.docker deploy.container >>= function
  | Error err ->
    L.error "[%s]Error in stopping of deploy %s, container %s:\n%s"
      t.name
      (spec_label deploy.spec) (Docker.container_to_string deploy.container) (Exn.to_string err);
    return ()
  | Ok _ ->
    return ()

let new_deploy t edn prev_deploy stop_before_start =
  parse_spec t edn
  >>=? fun (spec, watchers) ->
  Discoveries.apply t spec
  >>=? fun (discoveries, spec') ->
  let spec' = merge_envs_to_spec spec' t.envs in
  match (spec', prev_deploy) with
  | (spec, Some prev_deploy) when spec = prev_deploy.spec ->
    L.info "[%s] Specs are same" t.name;
    Watchers.stop watchers;
    Discoveries.stop discoveries;
    Ok prev_deploy |> return
  | _ ->
    (match (stop_before_start, prev_deploy) with
     | (true, Some deploy) -> stop t deploy
     | _ -> return ()) >>= fun () ->
    prepare_devices spec' >>=? fun () ->
    let {Spec.Image.name;tag} = spec'.Spec.image in
    L.info "[%s] Start container. Image: %s, tag: %s" t.name name tag;
    Docker.start t.docker spec' >>=? fun (container, ports) ->
    register_services t spec' container ports >>= function
    | Error err ->
      Watchers.stop watchers;
      Discoveries.stop discoveries;
      (Docker.stop t.docker container >>= fun _ -> Error err |> return)
    | Ok services ->
      Ok { spec = spec';
           raw_spec = edn;
           container = container;
           services = services;
           stop_checks = stable_watcher t container services;
           stop_supervisor = None;
           created_at = now ();
           stable_at = None;
           discoveries = discoveries;
           watchers = watchers; }
      |> return

let clear_try_again t =
  match t.try_again with
  | Some e -> Clock.Event.abort_if_possible e ()
  | None -> ()

let schedule_try_again t edn =
  let e = Clock.Event.after (Time.Span.of_int_sec 5) in
  t.try_again <- Some e;
  (Clock.Event.fired e >>= fun _ ->
   Pipe.write t.events (TryAgain edn))
  |> don't_wait_for

let at_stable t deploy =
  let supervisor_watcher t supervisor deploy =
    supervisor >>= function
    | Ok () -> return ()
    | Error err -> Pipe.write t.events Down in
  let (supervisor, stop_supervisor) = Docker.supervisor t.docker deploy.container in
  supervisor_watcher t supervisor deploy |> don't_wait_for;
  { deploy with stop_supervisor = Some stop_supervisor;
                stable_at = Some (now ())}

let init_deploy t edn =
  clear_try_again t;
  new_deploy t edn None false >>= function
  | Ok deploy -> Waiting deploy |> return
  | Error err ->
    L.error "[%s] Error while deploying:\n%s" t.name (Exn.to_string err);
    schedule_try_again t edn;
    return Init

let init_new_spec t edn =
  L.info "[%s] New spec was received, let's deploy it" t.name;
  init_deploy t edn

let init_try_again t edn =
  L.info "[%s] We will try to deploy previously failed spec again" t.name;
  init_deploy t edn

let waiting_redeploy t deploy edn =
  clear_try_again t;
  new_deploy t edn (Some deploy) true >>= function
  | Ok deploy -> Waiting deploy |> return
  | Error err ->
    L.error "[%s] Error while deploying:\n%s" t.name (Exn.to_string err);
    schedule_try_again t edn;
    return Init

let waiting_new_spec t deploy edn =
  L.info "[%s] New spec was received while we are waiting for green health checks for previous one. We will stop the current one and will try to deploy this new spec" t.name;
  waiting_redeploy t deploy edn

let waiting_stop t deploy =
  stop t deploy >>| fun () ->
  Stopped

let waiting_stable t deploy =
  clear_try_again t;
  L.info "[%s] Now health checks are green, so we will be here with this spec and will wait for any changes" t.name;
  let deploy' = at_stable t deploy in
  Started deploy' |> return

let waiting_not_stable t deploy =
  L.error "[%s] Deploy is not stable. We had waited for green health checks for each service in spec. The period of waiting can be configured via `timeout` option in health check's spec" t.name;
  waiting_redeploy t deploy deploy.raw_spec

let waiting_environment_updated t deploy =
  L.info "[%s] Watcher or discovery has been changed, so we will redeploy current spec" t.name;
  waiting_redeploy t deploy deploy.raw_spec

let waiting_next_redeploy t current next edn =
  clear_try_again t;
  new_deploy t edn (Some next) true >>| function
  | Ok deploy -> WaitingNext (current, deploy)
  | Error err ->
    L.error "[%s] Error while deploying. Stays with stable %s. Error:\n %s"
      t.name (spec_label current.spec) (Exn.to_string err);
    schedule_try_again t edn;
    Started current

let waiting_next_new_spec t current next edn =
  L.info "[%s] New spec was received while we have two different deploys. We are waiting for green health checks for the last one, while the first one is stable. We will stop the last one and will try to deploy this new spec" t.name;
  waiting_next_redeploy t current next edn

let waiting_next_stop t current next =
  stop t next >>= fun () ->
  stop t current >>= fun () ->
  Stopped |> return

let waiting_next_stable t current next =
  let timeout = match current.spec.Spec.stop with
    | Spec.After n -> n
    | Spec.Before -> 0 in
  L.info "[%s] Now health checks of new spec are green. We will stop previous deploy after %i seconds. After that we will be here with this spec and will wait for any changes" t.name timeout;
  stop t ~timeout:timeout current >>= fun () ->
  let next' = at_stable t next in
  Started next' |> return

let waiting_next_not_stable t current next =
  L.error "[%s] Deploy is not stable. We had waited for green health checks for each service in spec. The period of waiting can be configured via `timeout` option in health check's spec. Now we will be here with previsous deploy (which is stable) and will try again to deploy the next oe after few seconds" t.name;
  stop t next >>= fun () ->
  schedule_try_again t next.raw_spec;
  Started current |> return

let waiting_next_environment_updated t current next =
  L.info "[%s] Watcher or discovery has been changed while we have two different deploys. We are waiting for green health checks for the last one, while the first one is stable. We will stop the last one and will try to deploy this new spec" t.name;
  waiting_next_redeploy t current next next.raw_spec

let waiting_next_down t current next =
  L.error "[%s] While we were waiting green health checks for next deploy, the current one was crashed. We will forget about crashed deploy and will continue to wait for next deploy" t.name;
  stop t current >>= fun () ->
  Waiting next |> return

let started_before t deploy edn =
  clear_try_again t;
  new_deploy t edn (Some deploy) true >>= function
  | Ok deploy -> Waiting deploy |> return
  | Error err ->
    L.error "[%s] Error while deploying:\n%s" t.name (Exn.to_string err);
    schedule_try_again t edn;
    return Init

let started_after t deploy edn =
  clear_try_again t;
  new_deploy t edn None false >>= function
  | Ok next_deploy -> WaitingNext (deploy, next_deploy) |> return
  | Error err ->
    L.error "[%s] Error while deploying:\n%s" t.name (Exn.to_string err);
    schedule_try_again t edn;
    return (Started deploy)

let started_new_spec_before t deploy edn =
  L.info "[%s] New spec was received. According to stop strategy in spec we will stop current deploy in advance. Then start new deploy with new spec" t.name;
  started_before t deploy edn

let started_new_spec_after t deploy edn =
  L.info "[%s] New spec was received. According to stop strategy in spec we will start new deploy in parallel with previous. If the new one will be successful (started and health checks passed) the previous one will be stopped." t.name;
  started_after t deploy edn

let started_environment_updated_before t deploy =
  L.info "[%s] Watcher or discovery has been changed. According to stop strategy in spec we will stop current deploy in advance. Then start new deploy with new spec." t.name;
  started_before t deploy deploy.raw_spec

let started_environment_updated_after t deploy =
  L.info "[%s] Watcher or discovery has been changed. According to stop strategy in spec we will start new deploy in parallel with previous. If the new one will be successful (started and health checks passed) the previous one will be stopped." t.name;
  started_after t deploy deploy.raw_spec

let started_stop t deploy =
  stop t deploy >>= fun () ->
  Stopped |> return

let started_down t deploy =
  L.error "[%s] Container with current deploy was crashed. We will try to redeploy it in few seconds" t.name;
  stop t deploy >>| fun () ->
  schedule_try_again t deploy.raw_spec;
  Init

let started_try_again t deploy edn =
  L.info "[%s] Try again previously failed deploy" t.name;
  started_after t deploy edn

let unexpected t state e =
  L.error "[%s] Unexpected event in %s state:\n%s" t.name state (sexp_of_event e |> Sexp.to_string_hum)

let apply t = function
  | Init -> (function
      | NewSpec edn -> init_new_spec t edn
      | TryAgain edn -> init_try_again t edn
      | Stop -> return Stopped
      | e -> unexpected t "Init" e; Init |> return)
  | Waiting deploy -> (function
      | NewSpec spec -> waiting_new_spec t deploy spec
      | Stop -> waiting_stop t deploy
      | Stable -> waiting_stable t deploy
      | NotStable -> waiting_not_stable t deploy
      | EnvironmentUpdated -> waiting_environment_updated t deploy
      | e -> unexpected t "Waiting" e; Waiting deploy |> return)
  | WaitingNext (current, next) -> (function
      | NewSpec edn -> waiting_next_new_spec t current next edn
      | Stop -> waiting_next_stop t current next
      | Stable -> waiting_next_stable t current next
      | NotStable -> waiting_next_not_stable t current next
      | EnvironmentUpdated -> waiting_next_environment_updated t current next
      | Down -> waiting_next_down t current next
      | e -> unexpected t "WaitingNext" e; WaitingNext (current, next) |> return)
  | Started deploy -> (function
      | NewSpec edn -> (match deploy.spec.Spec.stop with
          | Spec.Before -> started_new_spec_before t deploy edn
          | Spec.After _ -> started_new_spec_after t deploy edn)
      | TryAgain edn as e -> (match deploy.spec.Spec.stop with
          | Spec.Before -> unexpected t "Started" e; Started deploy |> return
          | Spec.After _ -> started_try_again t deploy edn)
      | Stop -> started_stop t deploy
      | EnvironmentUpdated -> (match deploy.spec.Spec.stop with
          | Spec.Before -> started_environment_updated_before t deploy
          | Spec.After _ -> started_environment_updated_after t deploy)
      | Down -> started_down t deploy
      | e -> unexpected t "Started" e; Started deploy |> return)
  | Stopped -> (fun e -> unexpected t "Stopped" e; Stopped |> return)

let spec_watcher t pipe =
  let rec spec_watcher () =
    Pipe.read pipe >>= function
    | `Eof -> assert false
    | `Ok s -> let res = try
                   Ok (Edn.from_string s)
                 with exc -> Error exc in
      match res with
      | Ok edn ->
        Pipe.write t.events (NewSpec edn) >>= fun _ ->
        spec_watcher ()
      | Error exn ->
        L.error "[%s] Error in parsing spec from: %s" t.name (Exn.to_string exn);
        spec_watcher () in
  spec_watcher ()

let serialize_state state =
  state_to_yojson state |> Yojson.Safe.to_string

let worker t events =
  let rec tick state =
    (* print_endline (serialize_state state); *)
    (match t.advertiser with
     | Some adv ->
       Advertiser.advertise adv t.name (serialize_state state)
     | None -> return ()) >>= fun () ->
    Pipe.read events >>= function
    | `Eof -> assert false
    | `Ok change ->
      L.debug "New event:\n %s" (sexp_of_event change |> Sexp.to_string_hum);
      apply t state change >>= function
      | Stopped -> return ()
      | state' -> tick state' in
  tick Init

let rec init_advertise t =
  match t.advertiser with
  | Some adv ->
    (Advertiser.init adv t.name >>= function
      | Error exn ->
        L.error "[%s] Error in advertise init, try again" t.name;
        after (Time.Span.of_int_sec 5) >>= fun () ->
        init_advertise t
      | Ok () -> return ())
  | None -> return ()

let start ~name ~consul ~docker ~watcher ~advertiser ~envs =
  let (r, w) = Pipe.create () in
  let t = { consul; docker;
            advertiser; name; envs;
            events = w; try_again = None } in
  spec_watcher t watcher |> don't_wait_for;
  init_advertise t >>| fun () ->
  let worker = worker t r in
  (fun () ->
     Pipe.write t.events Stop >>= fun () ->
     worker)
