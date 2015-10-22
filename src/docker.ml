open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

module CA = Cohttp_async
module RM = Utils.RunMonitor

type t = { endpoint: Uri.t }

type container = Id of string | Name of string

let container_to_string = function
  | Id v -> v
  | Name v -> v

let create endpoint = { endpoint = Uri.of_string endpoint }

let make_uri ?(query_params = []) t path =
  (Uri.with_path t.endpoint path |> Uri.with_query') query_params

(* let rename docker name = *)

let rm docker container = Error (Failure "foo") |> return

let pull_image t image =
  let is_error line =
    let open Yojson.Basic.Util in
    let parse () = Yojson.Basic.from_string line |> member "Error" |> to_string_option in
    try parse () |> function
      | Some error_str -> Error (Failure error_str)
      | None -> Ok ()
    with exc -> Error (Failure "Parsing failed") in
  let rec error_checker r =
    Pipe.read r >>= function
    | `Eof -> Ok () |> return
    | `Ok v -> (match (is_error v) with
        | Error e ->
          Utils.Pipe.dummy_reader r |> don't_wait_for;
          Error e |> return
        | Ok () -> error_checker r) in
  let params = Spec.Image.([("fromImage", image.name); ("tag", image.tag)]) in
  let uri = make_uri t ~query_params:params "/images/create" in
  let do_req () = Client.post uri in
  try_with do_req >>=? Utils.HTTP.not_200_as_error >>=? fun (resp, body) ->
  CA.Body.to_pipe body |> Utils.Pipe.to_lines |> error_checker

let receive_image_id t image =
  let uri = make_uri t Spec.Image.(sprintf "/images/%s:%s/json" image.name image.tag) in
  Utils.HTTP.simple uri
    ~parser: (fun v -> Yojson.Basic.Util.(v |> member "Id" |> to_string))

let stop t container = Error (Failure "foo") |> return

(* cmd := &createContainerCmd{ *)
(*    Host:    spec.Host, *)
(*    User:    spec.User, *)
(*    Image:   spec.Image.Id, *)
(*    Cmd:     spec.Cmd, *)
(*    Env:     envs, *)
(*    Volumes: volumes, *)
(*    HostConfig: hostConfig{ *)
(*      Binds:        binds, *)
(*      PortBindings: portBindings, *)
(*      Privileged:   spec.Privileged, *)
(*      NetworkMode:  spec.NetworkMode, *)
(*      LogConfig:    logs, *)
(*    }, *)
(*  } *)


module CreateContainer = struct
  module PortBinding = struct
    type t = {
      host_port : string [@key "HostPort"];
    } [@@deriving yojson, show]
  end

  type host_config = {
    binds : string list [@key "Binds"];
    port_bindings : Yojson.Safe.json [@key "PortBindings"] [@opaque];
    publish_all_ports : bool [@key "PublishAllPorts"];
    privileged : bool [@key "Privileged"] [@default false];
    network_mode : string option [@key "NetworkMode"] [@default Some "bridge"];
    log_config : Spec.Logs.t option [@key "LogConfig"];
  } [@@deriving yojson, show]

  type t = {
    host : string option [@key "Host"];
    user : string option [@key "User"];
    image : string [@key "Image"];
    cmd : string list [@key "Cmd"];
    envs : string list [@key "Env"];
    exposed_ports : Yojson.Safe.json [@key "ExposedPorts"] [@opaque];
    host_config : host_config [@key "HostConfig"];
  } [@@deriving yojson, show]
end

let service_to_protocol s = Spec.Service.(if s.udp then "udp" else "tcp")

let create_container t spec image_id =
  let params = match spec.Spec.name with Some v -> [("name", v)] | None -> [] in
  let uri = make_uri t ~query_params:params "/containers/create"  in
  let make_env e = Spec.Env.(sprintf "%s=%s" e.name e.value) in
  let make_port s = Spec.Service.(sprintf "%i/%s" s.port (service_to_protocol s)) in
  let make_exposed s = (make_port s, `Assoc []) in
  let make_port_binding s = Spec.Service.(match s.host_port with
      | Some p -> Some CreateContainer.PortBinding.(make_port s,
                                                    { host_port = string_of_int p} |> to_yojson)
      | None -> None) in
  let make_bind v = Spec.Volume.(sprintf "%s:%s" v.from v.to_) in
  let port_bindings = `Assoc (List.filter_map spec.Spec.services make_port_binding) in
  let host_config = Spec.({ CreateContainer.
                            binds = List.map spec.volumes make_bind;
                            port_bindings = port_bindings;
                            publish_all_ports = true;
                            privileged = spec.privileged;
                            network_mode = spec.network_mode;
                            log_config = spec.logs; }) in
  let body = Spec.({ CreateContainer.
                     host = spec.host;
                     user = spec.user;
                     image = image_id;
                     cmd = spec.cmd;
                     envs = List.map spec.envs make_env;
                     exposed_ports = `Assoc (List.map spec.services make_exposed);
                     host_config = host_config; }) in
  let body' = body |> CreateContainer.to_yojson |> Yojson.Safe.to_string in
  Utils.HTTP.(simple uri ~req:Post ~body:body'
                ~parser: (fun v -> Yojson.Basic.Util.(v |> member "Id" |> to_string)))

(* Ignores any error *)
let rename_old_container t spec =
  match spec.Spec.name with
  | None -> Ok () |> return
  | Some n ->
    let new_name = Utils.random_str 10 in
    let uri = make_uri t (sprintf "/containers/%s/rename?name=%s" n new_name) in
    Utils.HTTP.(simple uri ~req:Post
                  ~parser: (fun _ -> ())) >>| function
    | Error err -> print_endline "some rename error!"; Ok ()
    | Ok () -> Ok ()

let start_container t spec container =
  let uri = make_uri t (sprintf "/containers/%s/start" container) in
  Utils.HTTP.(simple uri ~req:Post ~parser: (fun _ -> ()))

let receive_mapping t spec container =
  let uri = make_uri t (sprintf "/containers/%s/json" container) in
  let parse_service data s =
    match spec.Spec.network_mode with
    | Some "host" -> Spec.Service.(s.port, s.port)
    | _ ->
      let key = Spec.Service.(sprintf "%d/%s" s.port (service_to_protocol s)) in
      let open Yojson.Basic.Util in
      let to_ = data
                |> member "NetworkSettings"
                |> member key |> index 0
                |> member "HostPort" |> to_string |> int_of_string in
      (s.Spec.Service.port, to_) in
  Utils.HTTP.(simple uri ~req:Post
                ~parser: (fun v -> List.map spec.Spec.services (parse_service v)))

(* val start : t -> Spec.t -> ((container * (int * int) list), exn) Result.t Deferred.t *)
let start t spec =
  let i = spec.Spec.image in
  pull_image t i >>=? fun () ->
  receive_image_id t i >>=?
  create_container t spec >>=? fun container ->
  let container' = Id container in
  (rename_old_container t spec >>=? fun () ->
   start_container t spec container >>=?  fun () ->
   receive_mapping t spec container) >>= function
  | Ok mapping -> Ok (container', mapping) |> return
  | Error err -> (stop t container' >>= fun _ -> Error err |> return )

let supervisor t container =
  let uri = make_uri t (sprintf "/containers/%s/wait" (container_to_string container)) in
  let do_req () = Client.get uri in
  let monitor = RM.create () in
  let s = try_with do_req >>=? Utils.HTTP.not_200_as_error >>= fun res ->
    if RM.is_running monitor then Error (Failure "Container stopped") |> return
    else Ok () |> return in
  (s, RM.closer monitor)
