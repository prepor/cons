open Async.Std
open Core.Std

type t

type container

val container_to_string : container -> string

val create : ?auth_config_file:string -> string -> t

val watch_for_config_updates : t -> string option -> unit

val host : t -> string

val start : t -> Spec.t -> ((container * (int * int) list), exn) Result.t Deferred.t

val stop : t -> container -> (unit, exn) Result.t Deferred.t

(* After stopped it always returns Ok *)
val supervisor : t -> container -> (unit, exn) Result.t Deferred.t * (unit -> unit)
