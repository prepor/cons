open Async.Std

type t

val create : consul:Consul.t ->
  tags:string list -> prefix:string -> (t, exn) Deferred.Result.t

val stop : t -> unit Deferred.t

val init : t -> string -> (unit, exn) Deferred.Result.t

val advertise : t -> string -> string -> unit Deferred.t

val forget : t -> string -> unit Deferred.t

