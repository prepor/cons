open Core.Std
open Async.Std

module A = Async.Std

let random_str length =
  let buf = Bigbuffer.create length in
  let gen_char () = (match Random.int(26 + 26 + 10) with
      |  n when n < 26 -> int_of_char 'a' + n
      | n when n < 26 + 26 -> int_of_char 'A' + n - 26
      | n -> int_of_char '0' + n - 26 - 26)
                    |> char_of_int in
  for i = 0 to length do
    Bigbuffer.add_char buf (gen_char ())
  done;
  Bigbuffer.contents buf

let err_result_to_exn = function
  | Ok res -> Ok res
  | Error e -> Error (Error.to_exn e)

let yojson_to_result = function
  | `Ok v -> Ok v
  | `Error s -> Error (Failure s)

let failure fmt =
  ksprintf (fun msg -> (Failure msg)) fmt

module Yojson_assoc = struct
  module String = struct
    type t = (string * string) list [@@deriving show]

    let of_yojson = function
      | `Assoc xs as json->
        let f acc = (function
            | (k, `String v) -> (k, v)::acc
            | _ -> raise Exit) in
        (try `Ok (List.fold xs ~init:[] ~f) with
         | Exit -> `Error (sprintf "Can't parse as Assoc.List %s" (Yojson.Safe.to_string json)))
      | json -> `Error (sprintf "Can't parse as Assoc.List %s" (Yojson.Safe.to_string json))
    let to_yojson t =
      `Assoc (List.Assoc.map t (fun v -> `String v))
  end
end

module Deferred = struct
  let all_or_error' deferreds =
    Deferred.all deferreds >>| fun results ->
    match (List.find results (function | Ok _ -> false; | Error _ -> true)) with
    | Some (Error e) -> Error e
    | None -> Ok (List.map results (function | Ok v -> v; | Error _ -> assert false))
    | Some _ -> assert false

  (* val all_or_error : ('a, 'b) Result.t Deferred.t list -> ('a list, 'b) Result.t Deferred.t *)
  let all_or_error deferreds =
    let error = Ivar.create () in
    let results = List.map deferreds
        (fun d -> d >>| function | Ok v -> Ok v
                                 | Error err -> Ivar.fill_if_empty error (Error err); (Error err)) in
    let results' = all_or_error' results in
    choose [choice (error |> Ivar.read) Fn.id;
            choice results' Fn.id]
end

module HTTP = struct
  exception BadStatus of Cohttp.Code.status_code * string

  let body_empty status body =
    match status with
    | `No_content -> return `Empty
    | `Not_modified -> return `Empty
    | _ ->
      Cohttp_async.Body.is_empty body >>= function
      | true -> return `Empty
      | false -> Cohttp_async.Body.to_string body >>| fun str -> `Body str

  let not_200_as_error (resp, body) =
    match Cohttp.Response.status resp with
    | #Cohttp.Code.success_status -> Ok (resp, body) |> return
    | `Not_modified -> Ok (resp, body) |> return
    | status ->
      body_empty status body >>| function
      | `Empty -> Error (BadStatus (status, "[empty body]"))
      | `Body s -> Error (BadStatus (status, s))

  type http_method = Get | Post | Delete | Put

  let method_to_string = function
    | Get -> "GET"
    | Post -> "POST"
    | Delete -> "DELETE"
    | Put -> "PUT"

  let simple_builder handler ~parser =
    let parse = function
      | "" -> Result.try_with (fun () -> parser `Null)
      | body -> Result.try_with (fun () -> parser (Yojson.Basic.from_string body)) in

    let do_req uri res = try_with res >>=? not_200_as_error >>= function
      | Error err ->
        L.error "Request %s failed: %s" (Uri.to_string uri) (Exn.to_string err);
        Error err |> return
      | Ok (resp, body) ->
        L.debug "Request %s success: %s"
          (Uri.to_string uri) (Cohttp.Response.sexp_of_t resp |> Sexp.to_string_hum);
        body_empty (Cohttp.Response.status resp) body >>| function
        | `Empty -> parse ""
        | `Body s -> parse s in
    handler do_req

  let get_handler cont ?headers uri =
    cont uri (fun () -> Cohttp_async.Client.get ?headers uri)

  let delete_handler cont ?headers uri =
    cont uri (fun () -> Cohttp_async.Client.delete ?headers uri)

  let post_handler cont ?headers ?body uri =
    cont uri (fun () ->
        let body' = match body with
          | Some v -> Some (Cohttp_async.Body.of_string v) | None -> None in
        Cohttp_async.Client.post ?headers ?body:body' uri)

  let put_handler cont ?headers ?body uri =
    cont uri (fun () ->
        let body' = match body with
          | Some v -> Some (Cohttp_async.Body.of_string v) | None -> None in
        Cohttp_async.Client.put ?headers ?body:body' uri)

  let get ~parser = simple_builder get_handler ~parser
  let post ~parser = simple_builder post_handler ~parser
  let put ~parser = simple_builder put_handler ~parser
  let delete ~parser = simple_builder delete_handler ~parser
end

module Pipe = struct
  let to_lines r =
    let buf = Bigbuffer.create 16 in
    let rec worker w =
      let detect_line s =
        let n = String.length s in
        let rec tick pos =
          if n = 0 || pos = n then
            return ()
          else
          if s.[pos] = '\n' then
            Pipe.write w (Bigbuffer.contents buf) >>=
            (fun () -> Bigbuffer.clear buf; tick (pos + 1))
          else
          if s.[pos] = '\r' && pos + 1 < n && s.[pos + 1] = '\n' then
            Pipe.write w (Bigbuffer.contents buf)
            >>= (fun () -> Bigbuffer.clear buf; tick (pos + 2))
          else
            (Bigbuffer.add_char buf s.[pos];
             tick (pos + 1)) in
        tick 0 in
      Pipe.read r >>= function
      | `Eof -> return ()
      | `Ok v -> detect_line v >>= fun () -> worker w in
    Pipe.init worker

  let rec dummy_reader r =
    Pipe.read r >>= function
    | `Eof -> return ()
    | `Ok _ -> dummy_reader r
end

module Assoc = struct
  let merge l1 l2 =
    List.fold l2 ~init:l1 ~f:(fun acc (k,v) -> List.Assoc.add acc k v)
end

module RunMonitor = struct
  type t = Monitor of (unit Ivar .t * (bool ref))

  let create () = (Monitor (Ivar.create (), ref true))

  let completed (Monitor (v, _)) = Ivar.fill v ()

  let is_running (Monitor (_, is_running)) = !is_running = true

  let close (Monitor (v, is_running)) = is_running := false; Ivar.read v

  let closer m = fun _ -> close m
end

module Option = struct
  let of_result = function
    | Error v -> None
    | Ok v -> Some v
end

module Base64 = Utils_base64

module Mount = struct
  open Re2.Std
  let is_mounted_regexp = Re2.create_exn "([/\\w])+\\s+on\\s+([/\\w])"
  let mapping () =
    Process.run_lines ~prog:"mount" ~args:[] () >>| err_result_to_exn >>|? fun res ->
    res
    |> List.filter_map ~f:(fun el -> Re2.find_submatches is_mounted_regexp el
                                     |> Option.of_result)
    |> List.filter_map ~f:(function
        | [| Some _; Some device; Some mountpoint |] -> Some (device, mountpoint)
        | _ -> None)
end

module Edn = struct
  open! Sexp
  let rec sexp_of_t (edn : Edn.t) =
    match edn with
    | `Keyword (Some prefix, v) -> List [(Atom "keyword"); (Atom (prefix ^ "/" ^ v))]
    | `Keyword (None, v) -> List [(Atom "keyword"); (Atom v)]
    | `Symbol (Some prefix, v) -> List [(Atom "symbol"); (Atom (prefix ^ "/" ^ v))]
    | `Symbol (None, v) -> List [(Atom "symbol"); (Atom v)]
    | `Assoc xs -> List ((Atom "assoc")::(List.map xs (fun (k, v) -> List [sexp_of_t k; sexp_of_t v])))
    | `List xs -> List ((Atom "list")::(List.map xs sexp_of_t))
    | `Vector xs -> List ((Atom "vector")::(List.map xs sexp_of_t))
    | `Set xs -> List ((Atom "set")::(List.map xs sexp_of_t))
    | `Char v -> List [(Atom "char"); (Atom v)]
    | `Decimal v -> List [(Atom "decimal"); (Atom v)]
    | `BigInt v -> List [(Atom "bigint"); (Atom v)]
    | `Tag (Some prefix, v, form) -> List [(Atom "keyword"); (Atom (prefix ^ "/" ^ v)); (sexp_of_t form)]
    | `Tag (None, v, form) -> List [(Atom "keyword"); (Atom v); (sexp_of_t form)]
    | `String v -> List [(Atom "string"); (Atom v)]
    | `Int v -> List [(Atom "int"); (Atom (string_of_int v))]
    | `Float v -> List [(Atom "int"); (Atom (string_of_float v))]
    | `Bool v -> List [(Atom "bool"); (Atom (string_of_bool v))]
    | `Null -> List [(Atom "null")]
end
