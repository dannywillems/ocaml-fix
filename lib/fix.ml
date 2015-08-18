type msgname =
  | Heartbeat
  | Logon
  | Logout

let msgtype_of_msgname = function
  | Heartbeat -> "0"
  | Logon -> "A"
  | Logout -> "5"

let msgname_of_msgtype = function
  | "0" -> Some Heartbeat
  | "A" -> Some Logon
  | "5" -> Some Logout
  | _ -> None

type fieldname =
  | BeginString [@value 8]
  | BodyLength [@value 9]
  | CheckSum [@value 10]
  | SenderCompId [@value 49]
  | TargetCompId [@value 56]
  | Text [@value 58]
  | HeartBtInt [@value 108]
  | ResetSeqNumFlag [@value 141]
  | Username [@value 553]
  | Password [@value 554]
      [@@deriving enum]

type field = {
  tag: int;
  value: string
} [@@deriving show,create]

type msg = field list [@@deriving show]

let field_of_string s =
  try
    let i = String.index s '=' in
    { tag = int_of_string @@ String.sub s 0 i;
      value = String.sub s (i+1) (String.length s - i - 1)
    }
  with _ -> invalid_arg ("field_of_string: " ^ s)

let string_of_field { tag; value } =
  let buf = Buffer.create 128 in
  Buffer.add_string buf @@ string_of_int tag;
  Buffer.add_char buf '=';
  Buffer.add_string buf value;
  Buffer.add_char buf '\001';
  Buffer.contents buf

let string_of_msg fields =
  let buf = Buffer.create 128 in
  List.iter
    (fun field -> Buffer.add_string buf @@ string_of_field field) fields;
  let res = Buffer.contents buf in
  let v = ref 0 in
  String.iter (fun c -> v := !v + Char.code c) res;
  Buffer.add_string buf ("10=" ^ string_of_int (!v mod 256) ^ "\001");
  Buffer.contents buf

let body_length fields =
  List.fold_left
    (fun a { tag; value } ->
       a + 2 + String.length value +
       String.length (string_of_int tag)
    )
    0 fields

let msg_maker ?(major=4) ?(minor=4) ~sendercompid ~targetcompid () =
  let seqnum = ref 1 in
  fun msgtype fields ->
    let verstring = Printf.sprintf "FIX.%d.%d" major minor in
    let timestring =
      let open Unix in
      let timeofday = gettimeofday () in
      let ms, _ = modf timeofday in
      let tm = timeofday |> gmtime in
      Printf.sprintf "%d%02d%02d-%02d:%02d:%02d.%3.0f"
        (1900 + tm.tm_year) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour
        tm.tm_min tm.tm_sec (ms *. 1000.) in
    let ver = create_field ~tag:8 ~value:verstring () in
    let msgseqnum = create_field ~tag:34 ~value:(string_of_int !seqnum) () in
    let typ = create_field ~tag:35 ~value:msgtype () in
    let sendcompid = create_field ~tag:49 ~value:sendercompid () in
    let targetcompid = create_field ~tag:56 ~value:targetcompid () in
    let sendingtime = create_field ~tag:52 ~value:timestring () in
    let fields = typ :: msgseqnum :: sendcompid :: targetcompid ::
                 sendingtime :: fields in
    let msglen = body_length fields in
    let length = create_field ~tag:9 ~value:(string_of_int msglen) () in
    incr seqnum;
    pred !seqnum, ver :: length :: fields

let read_msg s ~pos ~len =
  let rec inner acc pos =
    try
      let i = String.index_from s pos '\001' in
      if i > pos + len then raise Not_found
      else
        let sub = String.sub s pos (i - pos) in
        inner ((field_of_string sub) :: acc) (succ i)
    with Not_found -> List.rev acc
  in inner [] pos

let write_msg fields buf ~pos =
  let msg = string_of_msg fields in
  let msg_len = String.length msg in
  Bytes.blit_string msg 0 buf pos msg_len
