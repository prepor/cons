module StdStream = Stream

open! Core.Std
open! Async.Std

type auth = {
  username : string;
  password : string;
} [@@deriving sexp]

type t = {
  endpoint : Async_http.addr;
  config_path : string option;
  mutable config : (string, auth) List.Assoc.t;
}

type id = string [@@deriving sexp, yojson]

let load_config_exn config_path =
  let parse_auth v =
    let auth = Yojson.Basic.Util.(v |> member "auth" |> to_string |> Utils.Base64.decode) in
    let parts = String.split auth ~on:':' in
    let username = List.hd_exn parts in
    let password = String.concat (List.tl_exn parts) in
    {username; password} in
  let%map contents = Reader.file_contents config_path in
  let json = Yojson.Basic.from_string contents in
  let auths = Yojson.Basic.Util.(json |> member "auths" |> to_assoc) in
  List.Assoc.map ~f:parse_auth auths

let load_config = function
| None -> return []
| Some config_path ->
    match%map try_with (fun () -> load_config_exn config_path) with
    | Ok v ->
        Logs.app (fun m -> m "Docker config loaded from %s: %s" config_path
                     (List.Assoc.sexp_of_t String.sexp_of_t sexp_of_auth v
                      |> Sexp.to_string_hum));
        v
    | Error exn ->
        Logs.warn (fun m -> m "Error while loading Docker config from %s: %s" config_path (Exn.to_string exn));
        []

let create ~endpoint ~config_path =
  let%map config = load_config config_path in
  {endpoint; config_path; config}

let reload_config t =
  let%map config' = load_config t.config_path in
  t.config <- config'

let is_running t id =
  let%map res = Async_http.(request_of_addr t.endpoint
                            |> path (sprintf "/containers/%s/json" id)
                            |> parser (fun v ->
                                let open Yojson.Basic in
                                let json = from_string v in
                                Util.(json
                                      |> member "State"
                                      |> member "Status"
                                      |> to_string))
                            |> get) in
  match res with
  | Error err ->
      false
  | Ok {Async_http.Response.body} ->
      if body = "running" then true
      else false

let stop t id ~timeout =
  let%map _ = Async_http.(request_of_addr t.endpoint
                          |> path (sprintf "/containers/%s/stop" id)
                          |> query_param "t" (string_of_int timeout)
                          |> body ""
                          |> post) in
  ()


let wait_healthchecks t id ~timeout =
  let tick () =
    let%map res = Async_http.(request_of_addr t.endpoint
                              |> path (sprintf "/containers/%s/json" id)
                              |> parser (fun v ->
                                  let open Yojson.Basic in
                                  let json = from_string v in
                                  Util.(json
                                        |> member "State"
                                        |> member "Health"
                                        |> member "Status"
                                        |> to_string))
                              |> get) in
    match res with
    | Error err ->
        Logs.warn (fun m -> m "Error while receiving health-status about container %s: %s"
                      id (Exn.to_string err));
        `Continue ()
    | Ok {Async_http.Response.body} ->
        if body = "healthy" then `Complete ()
        else `Continue () in
  let wrapped () = tick () |> Cancellable.defer_wait in
  Cancellable.(
    let passing_waiter = worker ~sleep:500 ~tick:wrapped () in
    let timeout = after (Time.Span.of_int_sec timeout) |> defer in
    choose [
      passing_waiter --> (fun () -> `Passed);
      timeout --> (fun () -> `Not_passed);
    ])

let auth_headers t image =
  let encode {username; password} =
    `Assoc [("username", `String username); ("password", `String password)]
    |> Yojson.Basic.to_string
    |> Utils.Base64.encode in
  let registry = String.split ~on:'/' image |> List.hd_exn in
  match List.Assoc.find t.config registry with
  | Some v -> [("X-Registry-Auth", encode v)]
  | None -> []

let not_200_as_error res =
  let {Async_http.Response.status; body} = res in
  if status >= 200 && status < 300 then Ok res
  else Error (sprintf "Error while docker request (status %i): %s" status body)

let extract_image spec =
  Yojson.Basic.Util.(spec |> member "image" |> to_string_option)
  |> Result.of_option ~error:"Can't find image in spec"
  |> return

let map_result res =
  Result.(res |> map_error ~f:Exn.to_string >>= not_200_as_error)

let pull_image t image =
  Logs.app (fun m -> m "Pulling image %s" image);
  let error_checker s =
    let stream = Yojson.Basic.stream_from_string s in
    let rec check () =
      match StdStream.next stream with
      | exception StdStream.Failure -> Ok ()
      | exception err -> Error (Exn.to_string err)
      | v -> Yojson.Basic.Util.(match v |> member "error" |> to_string_option with
        | exception err -> Error (Exn.to_string err)
        | Some v -> Error ("Error while pulling: " ^ v)
        | None -> check ()) in
    check () in
  let%map res = Async_http.(request_of_addr t.endpoint
                            |> path "/images/create"
                            |> query_param "fromImage" image
                            |> headers (auth_headers t image)
                            |> body ""
                            |> post) in
  Result.(res |> map_result
          >>= (fun {Async_http.Response.body} -> error_checker body))

let delete_container t name =
  let%map _ = Async_http.(request_of_addr t.endpoint
                          |> path (sprintf "/containers/%s" name)
                          |> query_param "force" "true"
                          |> delete) in
  ()

let create_container t name spec =
  let name' = match Yojson.Basic.Util.(spec |> member "name" |> to_string_option) with
  | Some v -> v
  | None -> (sprintf "%s_%s" name (Utils.random_str 10)) in
  let%bind () = delete_container t name' in
  let%map res = Async_http.(request_of_addr t.endpoint
                            |> path "/containers/create"
                            |> query_param "name" name'
                            |> header "Content-Type" "application/json"
                            |> body (Yojson.Basic.to_string spec )
                            |> parser (fun v -> Yojson.Basic.(from_string v
                                                              |> Util.member "Id"
                                                              |> Util.to_string))
                            |> post) in
  Result.(res |> map_result >>| (fun {Async_http.Response.body} -> body))

let start_container t id =
  let%map res = Async_http.(request_of_addr t.endpoint
                            |> path (sprintf "/containers/%s/start" id)
                            |> body ""
                            |> post) in
  Result.(res |> map_result >>| (fun _ -> id))

let start t ~name ~spec =
  extract_image spec
  >>=? pull_image t
  >>=? (fun () -> create_container t name spec)
  >>=? start_container t
