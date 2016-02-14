open Async.Std
open Core.Std

let pipe_of_lines r =
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
