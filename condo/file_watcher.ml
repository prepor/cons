open Core.Std

open Async.Std

module RM = Utils.RunMonitor

let watch_loop path monitor w =
  let guarded_write v =
    if RM.is_running monitor then Pipe.write w v
    else return () in
  let rec tick prev_value =
    let next_tick ?(span=(Time.Span.of_ms 100.0)) prev_value' =
      after span >>= fun () -> tick prev_value' in
    let new_val = Result.try_with (fun () -> In_channel.read_all path) in
    (match new_val, prev_value with
     | Ok new_val', Some prev_value' when new_val' = prev_value' ->
       next_tick prev_value
     | Ok new_val', _ ->
       guarded_write new_val' >>= fun () ->
       next_tick (Some new_val')
     | Error err, _ ->
       L.error "Error while reading %s: %s" path (Utils.exn_to_string err);
       next_tick ~span:(Time.Span.of_int_sec 2) prev_value) in
  tick None

let spec_watcher ~path =
  let monitor = RM.create () in
  let w = watch_loop path monitor in
  let r = Pipe.init w in
  (r, RM.closer monitor)
