open! Core.Std
open! Async.Std

module HTTP = Cohttp
module HTTP_A = Cohttp_async
module Server = Cohttp_async.Server
module Client = Cohttp_async.Client

type t = {
  id : string;
  consul : Consul.t;
  prefix : string;
  session : string;
  advertisements : (string * string) Pipe.Writer.t;
  worker : unit Deferred.t;
}

let path id prefix name =
  Filename.concat prefix (id ^ "_" ^ name)

let init t name =
  Consul.put t.consul ~path:(path t.id t.prefix name) ~session:t.session ~body:""

let advertise t name value =
  Pipe.write t.advertisements (name, value)

let forget t name =
  Consul.delete t.consul ~path:(path t.id t.prefix name)
  |> Deferred.ignore

let start_service () =
  let callback ~body _a req =
    if (Uri.path req.HTTP.Request.uri) = "/gc" then
      (print_endline "Gc!";
       Gc.full_major ());
    Server.respond_with_string ~code:`OK "Condo is alive!\n" in
  let port_waiter = Ivar.create () in
  let where_to_listen =
    Tcp.Where_to_listen.create
      ~socket_type:Socket.Type.tcp
      ~address:(Socket.Address.Inet.create_bind_any ~port:0)
      ~listening_on:(fun (`Inet (_, port)) ->
          L.info "Advertiser started on %i" port;
          Ivar.fill port_waiter port;
          port) in
  (Server.create where_to_listen callback >>| Fn.ignore)
  |> don't_wait_for;
  Ivar.read port_waiter

let register_service ~id ~consul ~port ~tags =
  L.debug "Register itself as %s" id;
  let check = {Spec.Check.method_ = Spec.Check.HttpPath "/";
               interval = 5;
               (* useless heere *)
               timeout = 10} in
  let service = { Spec.Service.name = "condo";
                  tags = tags;
                  udp = false;
                  host_port = Some port;
                  port; check;} in
  L.debug "Service config: \n%s" (Spec.Service.show service);
  Consul.register_service consul ~id_suffix:id service [] port

let loop ~id ~prefix ~consul ~service ~advertisements =
  let tick (name, body) =
    Consul.put consul ~path:(path id prefix name) ~body ?session:None >>| function
    | Ok () -> ()
    | Error err -> L.error "Error while putting advertising value: %s" (Exn.to_string err) in
  Pipe.iter advertisements tick >>= fun () ->
  Consul.deregister_service consul service >>| function
  | Error exn -> L.error "Error while deregister advertiser: %s" (Exn.to_string exn)
  | Ok () -> ()

let wait_service consul service =
  Consul.wait_for_passing consul [(service, Time.Span.of_int_sec 30)] |> fst >>| function
  | `Pass -> Ok ()
  | `Error err -> Error err
  | `Closed -> assert false

let create_session consul id =
  Consul.create_session consul (sprintf "service:condo_%s" id)

let stop t =
  Pipe.close t.advertisements;
  t.worker

let create ~consul ~tags ~prefix =
  let id = Utils.random_str 10 in
  let (a_r, a_w) = Pipe.create () in
  start_service ()
  >>= fun port ->
  register_service ~id ~consul ~port ~tags
  >>=? fun service ->
  wait_service consul service >>=? fun () ->
  create_session consul id
  >>=? fun session ->
  let worker = loop ~id ~prefix ~consul ~service ~advertisements:a_r in
  let t = { id; consul; prefix; advertisements = a_w; session; worker} in
  return (Ok t)
