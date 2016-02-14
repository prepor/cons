open Core.Std
open! Async.Std

type t
type consul = t

module Service : sig
  type id
  type name
  val of_string : string -> name
end

val create : string -> t

(* After stop it never produces new vals *)
val key : t -> string -> string Pipe.Reader.t * (unit -> unit Deferred.t)

module KvBody : sig
  type t = {
    modify_index : int;
    key : string;
    flags : int;
    value : string;
  }
  val t_of_sexp : Sexp.t -> t
  val sexp_of_t : t -> Sexp.t
end

type prefix_change = [ `New of KvBody.t
                     | `Updated of KvBody.t
                     | `Removed of string ]

val prefix : t -> string -> prefix_change Pipe.Reader.t * (unit -> unit Deferred.t)

(* After stop it never produces new discoveries *)
val discovery : t -> ?tag:string -> Service.name -> (string * int) list Pipe.Reader.t * (unit -> unit Deferred.t)

val put : ?session:string -> t -> path:string -> body:string -> (unit, exn) Result.t Deferred.t

val delete : t -> path:string -> (unit, exn) Result.t Deferred.t

module CatalogService : sig
  type t =
    { id : string;
      address : string;
      node : string;
      port : int;
      tags : string list;}
end

val catalog_service : t -> string -> (string, CatalogService.t) List.Assoc.t Pipe.Reader.t * (unit -> unit Deferred.t)

module CatalogNode : sig
  type t =
    { address : string;
      node : string;}
end

val catalog_nodes : t -> CatalogNode.t list Pipe.Reader.t * (unit -> unit Deferred.t)

val register_service : t -> ?id_suffix:string -> Spec.Service.t -> (string * string) list -> int -> (Service.id, exn) Result.t Deferred.t

val deregister_service : t -> Service.id -> (unit, exn) Result.t Deferred.t

(* After stop it always returns Ok *)
val wait_for_passing : t -> (Service.id * Time.Span.t) list  ->
  [> `Closed | `Error of exn | `Pass ] Async.Std.Deferred.t * (unit -> unit)

val create_session : t -> string -> (string, exn) Result.t Deferred.t
