open! Core.Std
open! Async.Std

type advertise_config = {
  advertise_tags : string list;
  advertise_prefix : string;
}

type docker_config = {
  docker_endpoint : string;
  docker_auth_file : string option;
}

type consul_config = {
  consul_endpoint : string
}

let start_docker {docker_endpoint; docker_auth_file} =
  Docker.create ?auth_config_file:docker_auth_file docker_endpoint

let start_consul {consul_endpoint} =
  Consul.create consul_endpoint

let start_advertiser consul = function
  | None -> return None
  | Some {advertise_prefix; advertise_tags} ->
    Advertiser.create ~consul ~prefix:advertise_prefix ~tags:advertise_tags >>| function
    | Error err -> raise err
    | Ok v -> Some v

type watcher_event = Add of string * string Pipe.Reader.t
                   | Removed of string

(* TODO add support of filesystem watchers *)
let start_watcher consul endpoint =
  let path = match (Uri.scheme endpoint, Uri.host endpoint, Uri.path endpoint) with
    | (Some "consul", Some "", path) -> path
    | _ -> failwith (sprintf "Bad endpoint %s" (Uri.to_string endpoint)) in
  let (r, w) = Pipe.create () in
  let handle pipes = function
    | `New {Consul.KvBody.key; value} ->
      let key_r, key_w = Pipe.create () in
      Pipe.write w (Add (key, key_r)) >>= fun () ->
      Pipe.write key_w value >>| fun () ->
      (key, key_w)::pipes
    | `Updated {Consul.KvBody.key; value} ->
      let p = List.Assoc.find_exn pipes key in
      Pipe.write p value >>| fun () ->
      pipes
    | `Removed key ->
      Pipe.write w (Removed key) >>| fun () ->
      List.Assoc.remove pipes key in
  let (changes, _closer) = Consul.prefix consul path in
  Pipe.fold changes ~init:[] ~f:handle |> Deferred.ignore |> don't_wait_for;
  r

let start_supervisor ~docker ~advertiser ~consul ~endpoints ~envs =
  let specs = Pipe.interleave (List.map ~f:(start_watcher consul) endpoints) in
  let tick deployers = function
    | Add (key, watcher) ->
      let%map deployer = Deployer.start ~name:(Filename.basename key)
          ~docker ~consul ~advertiser ~watcher ~envs in
      (key, deployer)::deployers
    | Removed key ->
      let deployer = List.Assoc.find_exn deployers key in
      deployer () >>| fun () ->
      List.Assoc.remove deployers key in
  let worker = let%bind deployers = Pipe.fold specs ~init:[] ~f:tick in
    Deferred.List.iter deployers (fun (_, stopper) -> stopper ()) in
  (fun () -> Pipe.close_read specs; worker)

let start ~advertiser_config ~consul_config ~docker_config ~endpoints ~envs =
  (* let watcher = match (Uri.scheme endpoint, Uri.host endpoint, Uri.path endpoint) with *)
  (*   | (Some "consul", Some "", path) -> Consul.key consul path *)
  (*   | (Some "file", Some "", path) -> File_watcher.spec_watcher path *)
  (*   | (None, None, path) -> File_watcher.spec_watcher path *)
  (*   | _ -> failwith (sprintf "Bad endpoint %s" (Uri.to_string endpoint)) in *)
  let consul = start_consul consul_config in
  let docker = start_docker docker_config in
  let%map advertiser = start_advertiser consul advertiser_config in
  let stop_supervisor = start_supervisor ~docker ~advertiser ~consul ~endpoints ~envs in
  let stop () =
    stop_supervisor () >>= fun () ->
    (match advertiser with
     | Some v -> Advertiser.stop v
     | None -> return ()) in
  Shutdown.at_shutdown stop
