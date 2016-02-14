open Core.Std
open Async.Std

module Instance = struct
  type t = {
    id : string;
    node : string;
    address : string;
    port : int;
    tags : string list;
    state : Yojson.Safe.json;
  } [@@deriving yojson]
end

type snapshot = Instance.t String.Map.t

type change = Add of Instance.t | Remove of string | Update of Instance.t

type signal = change * snapshot

type event = Subscribe of signal Pipe.Reader.t * signal Pipe.Writer.t
           | Unsubscribe of signal Pipe.Reader.t
           | Snapshot of snapshot Ivar.t
           | Change of signal

type t = { control : event Pipe.Writer.t; }

type state = { instances : snapshot;
               subscribers : (signal Pipe.Reader.t, signal Pipe.Writer.t) List.Assoc.t;}

let snapshot_to_yojson snapshot =
  let res =
    String.Map.map snapshot Instance.to_yojson
    |> String.Map.to_alist in
  `Assoc res

let apply state = function
  | Snapshot res ->
    Ivar.fill res state.instances;
    state |> return
  | Subscribe (r, w) ->
    { state with subscribers = List.Assoc.add state.subscribers r w } |> return
  | Unsubscribe r ->
    { state with subscribers = List.Assoc.remove state.subscribers r} |> return
  | Change signal ->
    let (_, snapshot) = signal in
    List.Assoc.map state.subscribers (fun s -> Pipe.write s signal)
    |> List.map ~f:snd |> Deferred.all >>| fun _ ->
    { state with instances = snapshot }

let rec main_loop state r =
  Pipe.read r >>= function
  | `Ok v -> (apply state v) >>= fun state' -> main_loop state' r
  | `Eof -> assert false

let snapshot t =
  let res = Ivar.create () in
  Pipe.write t.control (Snapshot res) >>= fun () ->
  Ivar.read res

let subscribe t =
  let (r, w) = Pipe.create () in
  Pipe.write t.control (Subscribe (r, w)) >>| fun () ->
  r

let unsubscribe t r =
  Pipe.write t.control (Unsubscribe r)

module Watcher = struct
  type event = Services of Consul.CatalogService.t String.Map.t
             | KeyValue of Consul.CatalogService.t * string

  type t =
    { consul : Consul.t;
      keys_prefix : string;
      snapshot : snapshot;
      key_watchers : (string, (unit -> unit Deferred.t)) List.Assoc.t;
      out : signal Pipe.Writer.t;
      control_r : event Pipe.Reader.t;
      control_w : event Pipe.Writer.t; }

  let diff key_watchers consul_services =
    let current_keys = key_watchers |> List.map ~f:fst |> String.Set.of_list in
    let current'_keys = consul_services |> String.Set.of_map_keys in
    let new_keys = String.Set.diff current'_keys current_keys |> String.Set.to_list in
    let removed_keys = String.Set.diff current_keys current'_keys |> String.Set.to_list in
    (List.map new_keys (String.Map.find_exn consul_services),
     removed_keys)

  let apply_services t services =
    let (new_, removed) = diff t.key_watchers services in
    let new_key_watchers = List.map new_ (function {Consul.CatalogService.id} as s ->
        let (values, stopper) = Consul.key t.consul (sprintf "/%s/%s" t.keys_prefix id) in
        Pipe.iter values (fun v -> Pipe.write t.control_w (KeyValue (s, v))) |> don't_wait_for;
        (id, stopper)) in
    let key_watchers' = List.fold removed ~init:t.key_watchers ~f:(List.Assoc.remove ?equal:None) in
    let snapshot' = List.fold removed ~init:t.snapshot ~f:String.Map.remove in
    List.map removed (fun k ->
        let stopper = List.Assoc.find_exn t.key_watchers k in
        stopper ()) |> Deferred.all_ignore |> don't_wait_for;
    let t' = { t with key_watchers = List.concat [key_watchers'; new_key_watchers];
                      snapshot = snapshot'} in
    List.map removed ~f:(fun k ->
        Pipe.write t.out ((Remove k), t'.snapshot)) |> Deferred.all_ignore >>| fun () ->
    t'

  let make_instance service state =
    let {Consul.CatalogService.id; address; node; port; tags} = service in
    { Instance.id; address; node; port; tags;
      state = state;}

  let apply_key_value t service value =
    let {Consul.CatalogService.id} = service in
    Result.try_with (fun () -> Yojson.Safe.from_string value) |> return >>= function
    | Error err ->
      L.error "Error while reading state json for service %s: %s" id (Exn.to_string err);
      return t
    | Ok state ->
      let instance' = make_instance service state in
      let snapshot' = String.Map.add t.snapshot ~key:id ~data:instance' in
      let change = (match String.Map.mem t.snapshot id with
          | true -> Update instance'
          | false -> Add instance') in
      Pipe.write t.out (change, snapshot') >>| fun () ->
      { t with snapshot = snapshot' }

  let apply t = function
    | Services consul_services -> apply_services t consul_services
    | KeyValue (consul_service, value) -> apply_key_value t consul_service value

  let loop t =
    let rec tick t =
      Pipe.read t.control_r >>= function
      | `Ok v -> apply t v >>= tick
      | `Eof -> assert false in
    tick t

  let start consul keys_prefix =
    let (services, _closer) = Consul.catalog_service consul "condo" in
    let (r, out) = Pipe.create () in
    let (control_r, control_w) = Pipe.create () in
    let t = { consul; out; keys_prefix;
              control_r; control_w;
              snapshot = String.Map.empty;
              key_watchers = []; } in
    Pipe.transfer services control_w ~f:(fun v -> Services (String.Map.of_alist_exn v)) |> don't_wait_for;
    loop t |> don't_wait_for;
    r

end

let create consul ~prefix ~tag =
  let (r, w) = Pipe.create () in
  let state = { instances = String.Map.empty;
                subscribers = [];} in
  main_loop state r |> don't_wait_for;
  let watches = Watcher.start consul prefix in
  Pipe.transfer watches w (fun v -> Change v) |> don't_wait_for;
  { control = w }
