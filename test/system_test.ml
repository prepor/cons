open! Core.Std
open! Async.Std
open! Import

module S = System

let%expect_test "place snapshot" =
  let snapshot = Instance.init_snaphot () |> Instance.sexp_of_snapshot in
  let%bind s = system () in
  let%bind () = S.place_snapshot s ~name:"nginx" ~snapshot in
  print_endline (In_channel.read_all "/tmp/condo_state");
  [%expect {|
    test.native: [INFO] Can't read state file, initialized new one
    ((nginx Init)) |}]
