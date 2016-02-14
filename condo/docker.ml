module StdStream = Stream

open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

module CA = Cohttp_async
module RM = Utils.RunMonitor

type t = {
  endpoint : Uri.t;
  auth_config : (string, string) List.Assoc.t option
}

type container = { id : string; spec : Spec.t }

let container_to_string {id} = id

module AuthPair = struct
  type t = {
    username : string;
    password : string;
  } [@@deriving yojson, show]
end

let load_auth_config_exn config_file =
  let json_to_base64 json =
    Yojson.Safe.to_string json |> Utils.Base64.encode in
  let to_request_format json =
    let open Yojson.Basic.Util in
    let auth = json |> member "auth" |> to_string |> Utils.Base64.decode in
    let parts = String.split auth ~on:':' in
    let username = List.hd_exn parts in
    let password = String.concat (List.tl_exn parts) in
    { AuthPair.username; password } |> AuthPair.to_yojson in
  let load_auth_config' config_file =
    let contents = In_channel.read_all config_file in
    let body = Yojson.Basic.from_string contents in
    let open Yojson.Basic.Util in
    body |> member "auths" |> to_assoc
    |> List.Assoc.map ~f:(Fn.compose json_to_base64 to_request_format) in
  Option.map ~f:load_auth_config' config_file

let create ?auth_config_file endpoint =
  { endpoint = Uri.of_string endpoint;
    auth_config = load_auth_config_exn auth_config_file }

let host t = Uri.host_with_default t.endpoint ~default:""

let make_uri ?(query_params = []) t path =
  (Uri.with_path t.endpoint path |> Uri.with_query') query_params

let pull_image t image =
  let error_checker s =
    let stream = Yojson.Basic.stream_from_string s in
    let rec check () =
      match StdStream.next stream with
      | exception StdStream.Failure -> Ok ()
      | exception err -> Error err
      | v -> Yojson.Basic.Util.(match v |> member "error" |> to_string_option with
          | exception err -> Error err
          | Some v -> Error (Failure ("Error while pulling: " ^ v))
          | None -> check ()) in
    check () in
  let params = Spec.Image.([("fromImage", image.name); ("tag", image.tag)]) in
  let uri = make_uri t ~query_params:params "/images/create" in
  let headers = Option.(t.auth_config >>= fun auth_config' ->
                        String.split ~on:'/' image.Spec.Image.name |>
                        List.hd >>=
                        List.Assoc.find auth_config' >>| fun v ->
                        L.debug "Pulling with auth config %s" v;
                        Cohttp.Header.init_with "X-Registry-Auth" v)
                |> Option.value ~default: (Cohttp.Header.init ()) in
  let do_req () = Client.post ~headers uri in
  try_with do_req >>=? Utils.HTTP.not_200_as_error >>=? fun (resp, body) ->
  (CA.Body.to_string body >>| error_checker)

let receive_image_id t image =
  let uri = make_uri t Spec.Image.(sprintf "/images/%s:%s/json" image.name image.tag) in
  Utils.HTTP.get uri
    ~parser: (fun v -> Yojson.Basic.Util.(v |> member "Id" |> to_string))

let stop t container =
  let container' = (container_to_string container) in
  L.debug "Stop container %s" container';
  let query_params = match container.spec.Spec.kill_timeout with
    | Some t -> [("t", (string_of_int t))]
    | None -> [] in
  let uri = make_uri t Spec.Image.(sprintf "/containers/%s/stop" container') ~query_params in
  Utils.HTTP.post uri ~parser:Fn.ignore

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
  let params = match spec.Spec.name with
    (* docker can't work properly with containers with same names (even with
       renaming) see https://github.com/docker/docker/issues/15727 *)
    | Some v -> [("name", v ^ "_" ^ (Utils.random_str 10))]
    | None -> [] in
  let uri = make_uri t ~query_params:params "/containers/create"  in
  let make_env e = Spec.Env.(sprintf "%s=%s" e.name e.value) in
  let make_port s = Spec.Service.(sprintf "%i/%s" s.port (service_to_protocol s)) in
  let make_exposed s = (make_port s, `Assoc []) in
  let make_port_binding s = Spec.Service.(match s.host_port with
      | Some p ->
        let (k, v) = CreateContainer.PortBinding.(make_port s,
                                                  { host_port = string_of_int p} |> to_yojson) in
        Some (k, (`List [v]))
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
  L.debug "Container config:\n%s" body';
  Utils.HTTP.post uri ~body:body'
    ~headers: (Cohttp.Header.init_with "Content-Type" "application/json")
    ~parser: (fun v -> Yojson.Basic.Util.(v |> member "Id" |> to_string))

(* Ignores any error *)
let rename_old_container t spec =
  match spec.Spec.name with
  | None -> Ok () |> return
  | Some n ->
    let new_name = n ^ "_" ^ (Utils.random_str 10) in
    let uri = make_uri t (sprintf "/containers/%s/rename" n)
              |> fun uri -> Uri.add_query_param' uri ("name", new_name) in
    Utils.HTTP.post uri ~parser:Fn.ignore >>| function
    | Error err ->
      L.error "Renaming error (it can be ok) of %s: %s" n (Exn.to_string err);
      Ok ();
    | Ok () -> Ok ()

let start_container t spec container =
  let uri = make_uri t (sprintf "/containers/%s/start" container) in
  Utils.HTTP.post uri ~parser:Fn.ignore

let receive_mapping t spec container =
  let uri = make_uri t (sprintf "/containers/%s/json" container) in
  let parse_service data s =
    match spec.Spec.network_mode with
    | Some "host" -> Spec.Service.(s.port, s.port)
    | _ ->
      let key = Spec.Service.(sprintf "%d/%s" s.port (service_to_protocol s)) in
      let open Yojson.Basic.Util in
      let to_ = data
                |> member "NetworkSettings" |> member "Ports"
                |> member key |> index 0
                |> member "HostPort" |> to_string |> int_of_string in
      (s.Spec.Service.port, to_) in
  Utils.HTTP.get uri ~parser: (fun v -> List.map spec.Spec.services (parse_service v))

let start t spec =
  let i = spec.Spec.image in
  pull_image t i >>=? fun () ->
  receive_image_id t i >>=? fun image_id ->
  (* rename_old_container t spec >>= fun _ -> *)
  create_container t spec image_id >>=? fun container ->
  let container' = { id = container; spec = spec } in
  (start_container t spec container >>=? fun () ->
   receive_mapping t spec container) >>= function
  | Ok mapping -> Ok (container', mapping) |> return
  | Error err -> (stop t container' >>= fun _ -> Error err |> return )

let supervisor t container =
  let uri = make_uri t (sprintf "/containers/%s/wait" (container_to_string container)) in
  let do_req () = Client.post uri in
  let is_running = ref true in
  let s = try_with do_req >>=? Utils.HTTP.not_200_as_error >>= fun res ->
    if !is_running then
      Error (Failure "Container stopped") |> return
    else Ok () |> return in
  (s, fun () -> is_running := false)
