open Core.Std
open Async.Std

module Deferred : sig
  val all_or_error : ('a, 'b) Result.t Deferred.t list -> ('a list, 'b) Result.t Deferred.t
end

module HTTP : sig
  val not_200_as_error :
    Cohttp_async.Response.t * Cohttp_async.Body.t -> (Cohttp_async.Response.t * Cohttp_async.Body.t, exn) Result.t Async.Std.Deferred.t

  val body_empty : Cohttp.Code.status_code -> Cohttp_async.Body.t -> [`Body of string | `Empty] Async.Std.Deferred.t

  type http_method = Get | Post | Delete | Put

  val method_to_string : http_method -> string

  val get : parser:(Yojson.Basic.json -> 'a) -> ?headers:Cohttp.Header.t ->
    Uri.t -> ('a, exn) Result.t Async.Std.Deferred.t

  val post : parser:(Yojson.Basic.json -> 'a) -> ?headers:Cohttp.Header.t ->
    ?body:string -> Uri.t -> ('a, exn) Result.t Async.Std.Deferred.t

  val put : parser:(Yojson.Basic.json -> 'a) -> ?headers:Cohttp.Header.t ->
    ?body:string -> Uri.t -> ('a, exn) Result.t Async.Std.Deferred.t

  val delete : parser:(Yojson.Basic.json -> 'a) -> ?headers:Cohttp.Header.t ->
    Uri.t -> ('a, exn) Result.t Async.Std.Deferred.t

end

module Pipe : sig
  val to_lines : string Pipe.Reader.t -> string Pipe.Reader.t

  val dummy_reader : 'a Pipe.Reader.t -> unit Async.Std.Deferred.t
end

module Assoc : sig
  val merge : ('a, 'b) List.Assoc.t -> ('a, 'b) List.Assoc.t -> ('a, 'b) List.Assoc.t
end

module RunMonitor : sig
  type t

  val create : unit -> t

  val completed : t -> unit

  val is_running : t -> bool

  val close : t -> unit Async.Std.Deferred.t

  val closer : t -> (unit -> unit Async.Std.Deferred.t)
end

module Base64 : sig
  val decode : ?alphabet:string -> string -> string

  val encode : ?pad:bool -> ?alphabet:string -> string -> string
end

module Mount : sig
  val mapping : unit -> ((string * string) list, exn) Result.t Async.Std.Deferred.t
end

module Yojson_assoc : sig
  module String : sig
    type t = (string, string) List.Assoc.t
    val of_yojson : Yojson.Safe.json -> [ `Ok of t | `Error of string ]
    val to_yojson : t -> Yojson.Safe.json

    val pp : Format.formatter -> t -> unit
    val show : t -> string
  end
end

module Edn : sig
  val sexp_of_t : Edn.t -> Sexp.t
end

val random_str : int -> string

val err_result_to_exn : ('a, Error.t) Result.t -> ('a, exn) Result.t

val yojson_to_result : [`Error of string | `Ok of 'a] -> ('a, exn) Result.t

val failure : ('a, unit, string, exn) Core.Std.format4 -> 'a
