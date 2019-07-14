(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Astring
open Rresult
open Sexplib.Std

open Fixtypes

let int_of_string_result istr =
  match int_of_string_opt istr with
  | None -> R.error_msg "not an int"
  | Some i -> Ok i

let float_of_string_result istr =
  match float_of_string_opt istr with
  | None -> R.error_msg "not an float"
  | Some i -> Ok i

type _ typ  = ..

type (_,_) eq = Eq : ('a,'a) eq

module type T = sig
  type t [@@deriving sexp,yojson]
  val t : t typ
  val pp : Format.formatter -> t -> unit
  val tag : int
  val name : string
  val eq : 'a typ -> 'b typ -> ('a, 'b) eq option
  val parse : string -> (t, R.msg) result
end

type field =
    F : 'a typ * (module T with type t = 'a) * 'a -> field
type t = field

type printable = (string * Sexplib.Sexp.t) [@@deriving sexp]

let to_printable (F (_, m, v)) =
  let module F = (val m) in
  F.name, (F.sexp_of_t v)

let sexp_of_field t =
  sexp_of_printable (to_printable t)

let create typ m v = F (typ, m, v)

let sum_string s =
  String.fold_left (fun a c -> a + Char.to_int c) 0 s

let pp ppf (F (_, m, v)) =
  let module F = (val m) in
  Format.fprintf ppf "@[<v 1>%s: %a@]"
    F.name Sexplib.Sexp.pp (F.sexp_of_t v)

let print (F (_, m, v)) =
  let module F = (val m) in
  Format.asprintf "%d=%a" F.tag F.pp v

let to_yojson (F (_, m, v)) =
  let module F = (val m) in
  `Assoc [F.name, F.to_yojson v]

let field_to_yojson = to_yojson

let parse_raw str =
  match String.cut ~sep:"=" str with
  | None -> R.error_msgf "Missing '=' in '%s'" str
  | Some (tag, value) ->
    match int_of_string_opt tag with
    | None -> R.error_msg "Tag is not an int value"
    | Some tag -> R.ok (tag, value)

module SMap = Map.Make(String)

module type FIELD = sig
  include T
  val create : t -> field
  val find : 'a typ -> field -> 'a option
  val parse : int -> string -> field option
  val parse_yojson : string -> Yojson.Safe.t -> field option
end

module IntSet = Set.Make(struct
    type t = int
    let compare = Pervasives.compare
  end)

let field_mods = ref SMap.empty
let registered_tags = ref IntSet.empty

let register_field (module F : FIELD) =
  begin
    registered_tags :=
      match IntSet.find_opt F.tag !registered_tags with
      | Some _ ->
        invalid_arg (Printf.sprintf "register_field: tag %d already registered" F.tag)
      | None -> IntSet.add F.tag !registered_tags
  end ;
  field_mods := SMap.update F.name begin function
      | None -> Some (module F : FIELD)
      | Some _ ->
        invalid_arg "register field: already registered"
    end !field_mods

let field_of_sexp sexp =
  let name, s = printable_of_sexp sexp in
  SMap.fold begin fun _ m a ->
    let module F = (val m : FIELD) in
    match F.name = name, F.parse F.tag (Sexplib.Sexp.to_string s) with
    | true, Some t -> Some t
    | _ -> a
  end !field_mods None |> function
  | None -> failwith "field_of_sexp"
  | Some v -> v

let find :
  type a. a typ -> field -> a option = fun typ field ->
  SMap.fold begin fun _ m a ->
    let module F = (val m : FIELD) in
    match F.find typ field with
    | None -> a
    | Some aa -> Some aa
  end !field_mods None

let find_field = find

let same_kind ((F (typ, _, _)) as f1) ((F (typ', _, _)) as f2) =
  SMap.fold begin fun _ m a ->
    let module F = (val m : FIELD) in
    match F.find typ f1, F.find typ' f2 with
    | Some _, Some _ -> true
    | _ -> a
  end !field_mods false

exception Parsed_ok of t
let parse str =
  let open R.Infix in
  parse_raw str >>= fun (tag, v) ->
  try
    SMap.iter begin fun _ m ->
      let module F = (val m : FIELD) in
      match F.parse tag v with
      | None -> ()
      | Some v -> raise (Parsed_ok v)
    end !field_mods ;
    R.error_msgf "Unknown tag %d=%s" tag v
  with Parsed_ok t -> R.ok t

let of_yojson = function
  | `Assoc [name, v] -> begin
      try
        SMap.iter begin fun _ m ->
          let module F = (val m : FIELD) in
          match F.parse_yojson name v with
          | None -> ()
          | Some v -> raise (Parsed_ok v)
        end !field_mods ;
        Error (Format.asprintf "Unknown %s %a" name Yojson.Safe.pp v)
      with Parsed_ok t -> R.ok t
    end
  | #Yojson.Safe.t -> Error "Not a json object"

let field_of_yojson = of_yojson

module Set = struct
  include Set.Make(struct
      type t = field
      let compare = Pervasives.compare
    end)

  let to_yojson t =
    List.fold_right begin fun e a ->
      match to_yojson e with
      | `Assoc [name, v] -> (name, v) :: a
      | #Yojson.Safe.t -> assert false
    end (elements t) [] |>
    fun l -> `Assoc l

  let of_yojson = function
    | `Assoc fields -> begin try
          List.map begin fun a ->
            match of_yojson (`Assoc [a]) with
            | Ok v -> v
            | Error msg -> invalid_arg msg
          end fields |> fun r ->
          Ok (of_list r)
        with Invalid_argument msg -> Error msg
      end
    | #Yojson.Safe.t -> Error "not a json object"

  let sexp_of_t t = sexp_of_list sexp_of_field (elements t)
  let t_of_sexp s = of_list (list_of_sexp field_of_sexp s)

  let find_typ :
    type a. a typ -> t -> a option = fun typ fields ->
    fold begin fun f a ->
      match find_field typ f with
      | None -> a
      | Some v -> Some v
    end fields None

  let find_typ_bind :
    type a. a typ -> t -> f:(a -> 'b option) -> 'b option = fun typ fields ~f ->
    fold begin fun field a ->
      match find_field typ field with
      | None -> a
      | Some v -> f v
    end fields None

  let find_typ_map :
    type a. a typ -> t -> f:(a -> 'b) -> 'b option = fun typ fields ~f ->
    fold begin fun field a ->
      match find_field typ field with
      | None -> a
      | Some v -> Some (f v)
    end fields None

  let find_and_remove_typ :
    type a. a typ -> t -> (a * t) option = fun typ fields ->
    fold begin fun f a ->
      match find_field typ f with
      | None -> a
      | Some v -> Some (v, remove f fields)
    end fields None

  exception Removed of t
  let remove_typ :
    type a. a typ -> t -> t = fun typ fields ->
    try
      fold begin fun f a ->
        match find_field typ f with
        | None -> a
        | Some _ -> raise (Removed (remove f a))
      end fields fields
    with Removed s -> s
end

let parser =
  let open Angstrom in
  let lift_f s =
    let open R.Infix in
    let chk = String.fold_left (fun a c -> a + Char.to_int c) 1 s in
    parse s >>| fun t -> (t, chk mod 256) in
  lift lift_f @@ take_while1 (fun c -> c <> '\x01') <* char '\x01'

let add_to_buffer (len, sum) buf (F (_, m, v)) =
  let module F = (val m) in
  let open Buffer in
  let tag = string_of_int F.tag in
  let v = Format.asprintf "%a" F.pp v in
  add_string buf tag ;
  add_char buf '=' ;
  add_string buf v ;
  len + String.length tag + String.length v + 1,
  sum + sum_string tag + Char.to_int '=' + sum_string v

let serialize k t (F (_, m, v)) =
  let open Faraday in
  let module F = (val m) in
  let tag = string_of_int F.tag in
  let v = Format.asprintf "%a" F.pp v in
  k begin fun () ->
    write_string t tag ;
    write_char t '=' ;
    write_string t v
  end
    (String.length tag + String.length v + 1)
    (sum_string tag + Char.to_int '=' + sum_string v)

module Make (T : T) = struct
  include T

  let create v = (F (T.t, (module T), v))

  let find :
    type a. a typ -> field -> a option = fun typ (F (typ', _, v)) ->
    match eq typ typ' with
    | None -> None
    | Some Eq -> Some v

  let parse tag' v =
    match T.parse v with
    | Ok v when tag' = tag -> Some (F (T.t, (module T), v))
    | _ -> None

  let parse_yojson name' v =
    match T.of_yojson v with
    | Ok v when name' = name -> Some (F (T.t, (module T), v))
    | _ -> None
end

type _ typ += Account : string typ
module Account = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = Account
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 1
    let name = "Account"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Account, Account -> Some Eq
      | _ -> None
  end)
let () = register_field (module Account)

type _ typ += BeginString : Version.t typ
module BeginString = Make(struct
    type t = Version.t [@@deriving sexp,yojson]
    let t = BeginString
    let pp = Version.pp
    let parse = Version.parse
    let tag = 8
    let name = "BeginString"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | BeginString, BeginString -> Some Eq
      | _ -> None
  end)
let () = register_field (module BeginString)

type _ typ += BodyLength : int typ
module BodyLength = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = BodyLength
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 9
    let name = "BodyLength"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | BodyLength, BodyLength -> Some Eq
      | _ -> None
  end)
let () = register_field (module BodyLength)

type _ typ += CheckSum : string typ
module CheckSum = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = CheckSum
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 10
    let name = "CheckSum"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | CheckSum, CheckSum -> Some Eq
      | _ -> None
  end)
let () = register_field (module CheckSum)

type _ typ += ClOrdID : string typ
module ClOrdID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = ClOrdID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 11
    let name = "ClOrdID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | ClOrdID, ClOrdID -> Some Eq
      | _ -> None
  end)
let () = register_field (module ClOrdID)

type _ typ += OrigClOrdID : string typ
module OrigClOrdID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = OrigClOrdID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 41
    let name = "OrigClOrdID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OrigClOrdID, OrigClOrdID -> Some Eq
      | _ -> None
  end)
let () = register_field (module OrigClOrdID)

type _ typ += HandlInst : HandlInst.t typ
module HandlInst = Make(struct
    type t = HandlInst.t [@@deriving sexp,yojson]
    let t = HandlInst
    let pp = HandlInst.pp
    let parse = HandlInst.parse
    let tag = 21
    let name = "HandlInst"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | HandlInst, HandlInst -> Some Eq
      | _ -> None
  end)
let () = register_field (module HandlInst)

type _ typ += TimeInForce : TimeInForce.t typ
module TimeInForce = Make(struct
    type t = TimeInForce.t [@@deriving sexp,yojson]
    let t = TimeInForce
    let pp = TimeInForce.pp
    let parse = TimeInForce.parse
    let tag = 59
    let name = "TimeInForce"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | TimeInForce, TimeInForce -> Some Eq
      | _ -> None
  end)
let () = register_field (module TimeInForce)

type _ typ += ExecType : ExecType.t typ
module ExecType = Make(struct
    type t = ExecType.t [@@deriving sexp,yojson]
    let t = ExecType
    let pp = ExecType.pp
    let parse = ExecType.parse
    let tag = 150
    let name = "ExecType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | ExecType, ExecType -> Some Eq
      | _ -> None
  end)
let () = register_field (module ExecType)

type _ typ += MsgType : Fixtypes.MsgType.t typ
module MsgType = Make(struct
    type t = Fixtypes.MsgType.t [@@deriving sexp,yojson]
    let t = MsgType
    let pp = Fixtypes.MsgType.pp
    let tag = 35
    let parse = Fixtypes.MsgType.parse
    let name = "MsgType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MsgType, MsgType -> Some Eq
      | _ -> None
  end)
let () = register_field (module MsgType)

type _ typ += RefMsgType : Fixtypes.MsgType.t typ
module RefMsgType = Make(struct
    type t = Fixtypes.MsgType.t [@@deriving sexp,yojson]
    let t = RefMsgType
    let pp = Fixtypes.MsgType.pp
    let tag = 372
    let parse = Fixtypes.MsgType.parse
    let name = "RefMsgType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | RefMsgType, RefMsgType -> Some Eq
      | _ -> None
  end)
let () = register_field (module RefMsgType)

type _ typ += SendingTime : Ptime.t typ
module SendingTime = Make(struct
    type t = Ptime.t [@@deriving sexp,yojson]
    let t = SendingTime
    let pp = Fixtypes.UTCTimestamp.pp
    let parse = Fixtypes.UTCTimestamp.parse
    let tag = 52
    let name = "SendingTime"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SendingTime, SendingTime -> Some Eq
      | _ -> None
  end)
let () = register_field (module SendingTime)

type _ typ += TransactTime : Ptime.t typ
module TransactTime = Make(struct
    type t = Ptime.t [@@deriving sexp,yojson]
    let t = TransactTime
    let pp = Fixtypes.UTCTimestamp.pp
    let parse = Fixtypes.UTCTimestamp.parse
    let tag = 60
    let name = "TransactTime"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | TransactTime, TransactTime -> Some Eq
      | _ -> None
  end)
let () = register_field (module TransactTime)

type _ typ += MDEntryDate : Ptime.t typ
module MDEntryDate = Make(struct
    type t = Ptime.t [@@deriving sexp,yojson]
    let t = MDEntryDate
    let pp = Fixtypes.UTCTimestamp.pp
    let parse = Fixtypes.UTCTimestamp.parse
    let tag = 272
    let name = "MDEntryDate"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDEntryDate, MDEntryDate -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDEntryDate)

type _ typ += IssueDate : Ptime.t typ
module IssueDate = Make(struct
    type t = Ptime.t [@@deriving sexp,yojson]
    let t = IssueDate
    let pp = Fixtypes.UTCTimestamp.pp
    let parse = Fixtypes.UTCTimestamp.parse
    let tag = 225
    let name = "IssueDate"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | IssueDate, IssueDate -> Some Eq
      | _ -> None
  end)
let () = register_field (module IssueDate)

type _ typ += MaturityDate : Ptime.date typ
module MaturityDate = Make(struct
    type t = Ptime.date [@@deriving sexp,yojson]
    let t = MaturityDate
    let pp = Fixtypes.Date.pp
    let parse = Fixtypes.Date.parse
    let tag = 541
    let name = "MaturityDate"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MaturityDate, MaturityDate -> Some Eq
      | _ -> None
  end)
let () = register_field (module MaturityDate)

type _ typ += MaturityTime : Ptime.time typ
module MaturityTime = Make(struct
    type t = Ptime.time [@@deriving sexp,yojson]
    let t = MaturityTime
    let pp = Fixtypes.TZTimeOnly.pp
    let parse = Fixtypes.TZTimeOnly.parse
    let tag = 1079
    let name = "MaturityTime"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MaturityTime, MaturityTime -> Some Eq
      | _ -> None
  end)
let () = register_field (module MaturityTime)

type _ typ += SenderCompID : string typ
module SenderCompID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SenderCompID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 49
    let name = "SenderCompID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SenderCompID, SenderCompID -> Some Eq
      | _ -> None
  end)
let () = register_field (module SenderCompID)

type _ typ += TargetCompID : string typ
module TargetCompID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = TargetCompID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 56
    let name = "TargetCompID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | TargetCompID, TargetCompID -> Some Eq
      | _ -> None
  end)
let () = register_field (module TargetCompID)

type _ typ += MsgSeqNum : int typ
module MsgSeqNum = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = MsgSeqNum
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 34
    let name = "MsgSeqNum"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MsgSeqNum, MsgSeqNum -> Some Eq
      | _ -> None
  end)
let () = register_field (module MsgSeqNum)

type _ typ += RefSeqNum : int typ
module RefSeqNum = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = RefSeqNum
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 45
    let name = "RefSeqNum"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | RefSeqNum, RefSeqNum -> Some Eq
      | _ -> None
  end)
let () = register_field (module RefSeqNum)

type _ typ += SessionRejectReason : int typ
module SessionRejectReason = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = SessionRejectReason
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 373
    let name = "SessionRejectReason"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SessionRejectReason, SessionRejectReason -> Some Eq
      | _ -> None
  end)
let () = register_field (module SessionRejectReason)

type _ typ += RawData : string typ
module RawData = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = RawData
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 96
    let name = "RawData"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | RawData, RawData -> Some Eq
      | _ -> None
  end)
let () = register_field (module RawData)

type _ typ += Username : string typ
module Username = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = Username
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 553
    let name = "Username"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Username, Username -> Some Eq
      | _ -> None
  end)
let () = register_field (module Username)

type _ typ += Password : string typ
module Password = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = Password
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 554
    let name = "Password"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Password, Password -> Some Eq
      | _ -> None
  end)
let () = register_field (module Password)

type _ typ += Text : string typ
module Text = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = Text
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 58
    let name = "Text"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Text, Text -> Some Eq
      | _ -> None
  end)
let () = register_field (module Text)

type _ typ += TestReqID : string typ
module TestReqID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = TestReqID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 112
    let name = "TestReqID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | TestReqID, TestReqID -> Some Eq
      | _ -> None
  end)
let () = register_field (module TestReqID)

type _ typ += UserRequestID : string typ
module UserRequestID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = UserRequestID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 923
    let name = "UserRequestID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | UserRequestID, UserRequestID -> Some Eq
      | _ -> None
  end)
let () = register_field (module UserRequestID)

type _ typ += HeartBtInt : int typ
module HeartBtInt = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = HeartBtInt
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 108
    let name = "HeartBtInt"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | HeartBtInt, HeartBtInt -> Some Eq
      | _ -> None
  end)
let () = register_field (module HeartBtInt)

type _ typ += BeginSeqNo : int typ
module BeginSeqNo = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = BeginSeqNo
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 7
    let name = "BeginSeqNo"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | BeginSeqNo, BeginSeqNo -> Some Eq
      | _ -> None
  end)
let () = register_field (module BeginSeqNo)

type _ typ += EndSeqNo : int typ
module EndSeqNo = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = EndSeqNo
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 16
    let name = "EndSeqNo"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | EndSeqNo, EndSeqNo -> Some Eq
      | _ -> None
  end)
let () = register_field (module EndSeqNo)

type _ typ += SecurityReqID : string typ
module SecurityReqID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SecurityReqID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 320
    let name = "SecurityReqID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityReqID, SecurityReqID -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityReqID)

type _ typ += EncryptMethod : EncryptMethod.t typ
module EncryptMethod = Make(struct
    type t = EncryptMethod.t [@@deriving sexp,yojson]
    let t = EncryptMethod
    let pp = EncryptMethod.pp
    let parse = EncryptMethod.parse
    let tag = 98
    let name = "EncryptMethod"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | EncryptMethod, EncryptMethod -> Some Eq
      | _ -> None
  end)
let () = register_field (module EncryptMethod)

type _ typ += SecurityListRequestType : SecurityListRequestType.t typ
module SecurityListRequestType = Make(struct
    type t = SecurityListRequestType.t [@@deriving sexp,yojson]
    let t = SecurityListRequestType
    let pp = SecurityListRequestType.pp
    let parse = SecurityListRequestType.parse
    let tag = 559
    let name = "SecurityListRequestType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityListRequestType, SecurityListRequestType -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityListRequestType)

type _ typ += UserRequestType : UserRequestType.t typ
module UserRequestType = Make(struct
    type t = UserRequestType.t [@@deriving sexp,yojson]
    let t = UserRequestType
    let pp = UserRequestType.pp
    let parse = UserRequestType.parse
    let tag = 924
    let name = "UserRequestType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | UserRequestType, UserRequestType -> Some Eq
      | _ -> None
  end)
let () = register_field (module UserRequestType)

type _ typ += UserStatus : UserStatus.t typ
module UserStatus = Make(struct
    type t = UserStatus.t [@@deriving sexp,yojson]
    let t = UserStatus
    let pp = UserStatus.pp
    let parse = UserStatus.parse
    let tag = 926
    let name = "UserStatus"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | UserStatus, UserStatus -> Some Eq
      | _ -> None
  end)
let () = register_field (module UserStatus)

type _ typ += SecurityResponseID : string typ
module SecurityResponseID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SecurityResponseID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 322
    let name = "SecurityResponseID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityResponseID, SecurityResponseID -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityResponseID)

type _ typ += SecurityRequestResult : SecurityRequestResult.t typ
module SecurityRequestResult = Make(struct
    type t = SecurityRequestResult.t [@@deriving sexp,yojson]
    let t = SecurityRequestResult
    let pp = SecurityRequestResult.pp
    let parse = SecurityRequestResult.parse
    let tag = 560
    let name = "SecurityRequestResult"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityRequestResult, SecurityRequestResult -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityRequestResult)

type _ typ += NoRelatedSym : int typ
module NoRelatedSym = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = NoRelatedSym
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 146
    let name = "NoRelatedSym"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | NoRelatedSym, NoRelatedSym -> Some Eq
      | _ -> None
  end)
let () = register_field (module NoRelatedSym)

type _ typ += MDReqID : string typ
module MDReqID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = MDReqID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 262
    let name = "MDReqID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDReqID, MDReqID -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDReqID)

type _ typ += MassStatusReqID : string typ
module MassStatusReqID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = MassStatusReqID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 584
    let name = "MassStatusReqID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MassStatusReqID, MassStatusReqID -> Some Eq
      | _ -> None
  end)
let () = register_field (module MassStatusReqID)

type _ typ += PosReqID : string typ
module PosReqID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = PosReqID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 710
    let name = "PosReqID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | PosReqID, PosReqID -> Some Eq
      | _ -> None
  end)
let () = register_field (module PosReqID)

type _ typ += PosMaintRptID : string typ
module PosMaintRptID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = PosMaintRptID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 721
    let name = "PosMaintRptID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | PosMaintRptID, PosMaintRptID -> Some Eq
      | _ -> None
  end)
let () = register_field (module PosMaintRptID)

type _ typ += PosReqType : PosReqType.t typ
module PosReqType = Make(struct
    type t = PosReqType.t [@@deriving sexp,yojson]
    let t = PosReqType
    let pp = PosReqType.pp
    let parse = PosReqType.parse
    let tag = 724
    let name = "PosReqType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | PosReqType, PosReqType -> Some Eq
      | _ -> None
  end)
let () = register_field (module PosReqType)

type _ typ += MassStatusReqType : MassStatusReqType.t typ
module MassStatusReqType = Make(struct
    type t = MassStatusReqType.t [@@deriving sexp,yojson]
    let t = MassStatusReqType
    let pp = MassStatusReqType.pp
    let parse = MassStatusReqType.parse
    let tag = 585
    let name = "MassStatusReqType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MassStatusReqType, MassStatusReqType -> Some Eq
      | _ -> None
  end)
let () = register_field (module MassStatusReqType)

type _ typ += PosReqResult : PosReqResult.t typ
module PosReqResult = Make(struct
    type t = PosReqResult.t [@@deriving sexp,yojson]
    let t = PosReqResult
    let pp = PosReqResult.pp
    let parse = PosReqResult.parse
    let tag = 728
    let name = "PosReqResult"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | PosReqResult, PosReqResult -> Some Eq
      | _ -> None
  end)
let () = register_field (module PosReqResult)

type _ typ += SubscriptionRequestType : SubscriptionRequestType.t typ
module SubscriptionRequestType = Make(struct
    type t = SubscriptionRequestType.t [@@deriving sexp,yojson]
    let t = SubscriptionRequestType
    let pp = SubscriptionRequestType.pp
    let parse = SubscriptionRequestType.parse
    let tag = 263
    let name = "SubscriptionRequestType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SubscriptionRequestType, SubscriptionRequestType -> Some Eq
      | _ -> None
  end)
let () = register_field (module SubscriptionRequestType)

type _ typ += RefTagID : int typ
module RefTagID = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = RefTagID
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 371
    let name = "RefTagID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | RefTagID, RefTagID -> Some Eq
      | _ -> None
  end)
let () = register_field (module RefTagID)

type _ typ += MarketDepth : int typ
module MarketDepth = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = MarketDepth
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 264
    let name = "MarketDepth"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MarketDepth, MarketDepth -> Some Eq
      | _ -> None
  end)
let () = register_field (module MarketDepth)

type _ typ += MDUpdateType : MDUpdateType.t typ
module MDUpdateType = Make(struct
    type t = MDUpdateType.t [@@deriving sexp,yojson]
    let t = MDUpdateType
    let pp = MDUpdateType.pp
    let parse = MDUpdateType.parse
    let tag = 265
    let name = "MDUpdateType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDUpdateType, MDUpdateType -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDUpdateType)

type _ typ += MDUpdateAction : MDUpdateAction.t typ
module MDUpdateAction = Make(struct
    type t = MDUpdateAction.t [@@deriving sexp,yojson]
    let t = MDUpdateAction
    let pp = MDUpdateAction.pp
    let parse = MDUpdateAction.parse
    let tag = 279
    let name = "MDUpdateAction"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDUpdateAction, MDUpdateAction -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDUpdateAction)

type _ typ += OrdStatus : OrdStatus.t typ
module OrdStatus = Make(struct
    type t = OrdStatus.t [@@deriving sexp,yojson]
    let t = OrdStatus
    let pp = OrdStatus.pp
    let parse = OrdStatus.parse
    let tag = 39
    let name = "OrdStatus"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OrdStatus, OrdStatus -> Some Eq
      | _ -> None
  end)
let () = register_field (module OrdStatus)

type _ typ += MiscFeeType : MiscFeeType.t typ
module MiscFeeType = Make(struct
    type t = MiscFeeType.t [@@deriving sexp,yojson]
    let t = MiscFeeType
    let pp = MiscFeeType.pp
    let parse = MiscFeeType.parse
    let tag = 139
    let name = "MiscFeeType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MiscFeeType, MiscFeeType -> Some Eq
      | _ -> None
  end)
let () = register_field (module MiscFeeType)

type _ typ += CxlRejReason : CxlRejReason.t typ
module CxlRejReason = Make(struct
    type t = CxlRejReason.t [@@deriving sexp,yojson]
    let t = CxlRejReason
    let pp = CxlRejReason.pp
    let parse = CxlRejReason.parse
    let tag = 102
    let name = "CxlRejReason"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | CxlRejReason, CxlRejReason -> Some Eq
      | _ -> None
  end)
let () = register_field (module CxlRejReason)

type _ typ += CxlRejResponseTo : CxlRejResponseTo.t typ
module CxlRejResponseTo = Make(struct
    type t = CxlRejResponseTo.t [@@deriving sexp,yojson]
    let t = CxlRejResponseTo
    let pp = CxlRejResponseTo.pp
    let parse = CxlRejResponseTo.parse
    let tag = 434
    let name = "CxlRejResponseTo"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | CxlRejResponseTo, CxlRejResponseTo -> Some Eq
      | _ -> None
  end)
let () = register_field (module CxlRejResponseTo)

type _ typ += NoMDEntryTypes : int typ
module NoMDEntryTypes = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = NoMDEntryTypes
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 267
    let name = "NoMDEntryTypes"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | NoMDEntryTypes, NoMDEntryTypes -> Some Eq
      | _ -> None
  end)
let () = register_field (module NoMDEntryTypes)

type _ typ += NoMDEntries : int typ
module NoMDEntries = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = NoMDEntries
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 268
    let name = "NoMDEntries"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | NoMDEntries, NoMDEntries -> Some Eq
      | _ -> None
  end)
let () = register_field (module NoMDEntries)

type _ typ += MDEntryType : MDEntryType.t typ
module MDEntryType = Make(struct
    type t = MDEntryType.t [@@deriving sexp,yojson]
    let t = MDEntryType
    let pp = MDEntryType.pp
    let parse = MDEntryType.parse
    let tag = 269
    let name = "MDEntryType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDEntryType, MDEntryType -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDEntryType)

type _ typ += NoPositions : int typ
module NoPositions = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = NoPositions
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 702
    let name = "NoPositions"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | NoPositions, NoPositions -> Some Eq
      | _ -> None
  end)
let () = register_field (module NoPositions)

type _ typ += NoFills : int typ
module NoFills = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = NoFills
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 1362
    let name = "NoFills"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | NoFills, NoFills -> Some Eq
      | _ -> None
  end)
let () = register_field (module NoFills)

type _ typ += TotNumReports : int typ
module TotNumReports = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = TotNumReports
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 911
    let name = "TotNumReports"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | TotNumReports, TotNumReports -> Some Eq
      | _ -> None
  end)
let () = register_field (module TotNumReports)

type _ typ += NoMiscFees : int typ
module NoMiscFees = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = NoMiscFees
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 136
    let name = "NoMiscFees"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | NoMiscFees, NoMiscFees -> Some Eq
      | _ -> None
  end)
let () = register_field (module NoMiscFees)

type _ typ += TradeID : string typ
module TradeID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = TradeID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 1003
    let name = "TradeID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | TradeID, TradeID -> Some Eq
      | _ -> None
  end)
let () = register_field (module TradeID)

type _ typ += FillExecID : string typ
module FillExecID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = FillExecID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 1363
    let name = "FillExecID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | FillExecID, FillExecID -> Some Eq
      | _ -> None
  end)
let () = register_field (module FillExecID)

type _ typ += RawDataLength : int typ
module RawDataLength = Make(struct
    type t = int [@@deriving sexp,yojson]
    let t = RawDataLength
    let pp = Format.pp_print_int
    let parse = int_of_string_result
    let tag = 95
    let name = "RawDataLength"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | RawDataLength, RawDataLength -> Some Eq
      | _ -> None
  end)
let () = register_field (module RawDataLength)

type _ typ += ExecID : string typ
module ExecID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = ExecID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 17
    let name = "ExecID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | ExecID, ExecID -> Some Eq
      | _ -> None
  end)
let () = register_field (module ExecID)

type _ typ += OrderID : string typ
module OrderID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = OrderID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 37
    let name = "OrderID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OrderID, OrderID -> Some Eq
      | _ -> None
  end)
let () = register_field (module OrderID)

type _ typ += SecondaryOrderID : string typ
module SecondaryOrderID = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SecondaryOrderID
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 198
    let name = "SecondaryOrderID"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecondaryOrderID, SecondaryOrderID -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecondaryOrderID)

type _ typ += Symbol : string typ
module Symbol = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = Symbol
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 55
    let name = "Symbol"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Symbol, Symbol -> Some Eq
      | _ -> None
  end)
let () = register_field (module Symbol)

type _ typ += UnderlyingSymbol : string typ
module UnderlyingSymbol = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = UnderlyingSymbol
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 311
    let name = "UnderlyingSymbol"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | UnderlyingSymbol, UnderlyingSymbol -> Some Eq
      | _ -> None
  end)
let () = register_field (module UnderlyingSymbol)

type _ typ += SecurityDesc : string typ
module SecurityDesc = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SecurityDesc
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 107
    let name = "SecurityDesc"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityDesc, SecurityDesc -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityDesc)

type _ typ += SecurityType : SecurityType.t typ
module SecurityType = Make(struct
    type t = SecurityType.t [@@deriving sexp,yojson]
    let t = SecurityType
    let pp = SecurityType.pp
    let parse = SecurityType.parse
    let tag = 167
    let name = "SecurityType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityType, SecurityType -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityType)

type _ typ += Side : Side.t typ
module Side = Make(struct
    type t = Side.t [@@deriving sexp,yojson]
    let t = Side
    let pp = Side.pp
    let parse = Side.parse
    let tag = 54
    let name = "Side"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Side, Side -> Some Eq
      | _ -> None
  end)
let () = register_field (module Side)

type _ typ += PutOrCall : PutOrCall.t typ
module PutOrCall = Make(struct
    type t = PutOrCall.t [@@deriving sexp,yojson]
    let t = PutOrCall
    let pp = PutOrCall.pp
    let parse = PutOrCall.parse
    let tag = 201
    let name = "PutOrCall"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | PutOrCall, PutOrCall -> Some Eq
      | _ -> None
  end)
let () = register_field (module PutOrCall)

type _ typ += QtyType : QtyType.t typ
module QtyType = Make(struct
    type t = QtyType.t [@@deriving sexp,yojson]
    let t = QtyType
    let pp = QtyType.pp
    let parse = QtyType.parse
    let tag = 854
    let name = "QtyType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | QtyType, QtyType -> Some Eq
      | _ -> None
  end)
let () = register_field (module QtyType)

type _ typ += OrdType : OrdType.t typ
module OrdType = Make(struct
    type t = OrdType.t [@@deriving sexp,yojson]
    let t = OrdType
    let pp = OrdType.pp
    let parse = OrdType.parse
    let tag = 40
    let name = "OrdType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OrdType, OrdType -> Some Eq
      | _ -> None
  end)
let () = register_field (module OrdType)

type _ typ += OrdRejReason : OrdRejReason.t typ
module OrdRejReason = Make(struct
    type t = OrdRejReason.t [@@deriving sexp,yojson]
    let t = OrdRejReason
    let pp = OrdRejReason.pp
    let parse = OrdRejReason.parse
    let tag = 103
    let name = "OrdRejReason"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OrdRejReason, OrdRejReason -> Some Eq
      | _ -> None
  end)
let () = register_field (module OrdRejReason)

type _ typ += ExecTransType : ExecTransType.t typ
module ExecTransType = Make(struct
    type t = ExecTransType.t [@@deriving sexp,yojson]
    let t = ExecTransType
    let pp = ExecTransType.pp
    let parse = ExecTransType.parse
    let tag = 20
    let name = "ExecTransType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | ExecTransType, ExecTransType -> Some Eq
      | _ -> None
  end)
let () = register_field (module ExecTransType)

type _ typ += Price : float typ
module Price = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = Price
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 44
    let name = "Price"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Price, Price -> Some Eq
      | _ -> None
  end)
let () = register_field (module Price)

type _ typ += StopPx : float typ
module StopPx = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = StopPx
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 99
    let name = "StopPx"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | StopPx, StopPx -> Some Eq
      | _ -> None
  end)
let () = register_field (module StopPx)

type _ typ += AvgPx : float typ
module AvgPx = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = AvgPx
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 6
    let name = "AvgPx"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | AvgPx, AvgPx -> Some Eq
      | _ -> None
  end)
let () = register_field (module AvgPx)

type _ typ += LastPx : float typ
module LastPx = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = LastPx
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 31
    let name = "LastPx"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | LastPx, LastPx -> Some Eq
      | _ -> None
  end)
let () = register_field (module LastPx)

type _ typ += FillPx : float typ
module FillPx = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = FillPx
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 1364
    let name = "FillPx"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | FillPx, FillPx -> Some Eq
      | _ -> None
  end)
let () = register_field (module FillPx)

type _ typ += FillQty : float typ
module FillQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = FillQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 1365
    let name = "FillQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | FillQty, FillQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module FillQty)

type _ typ += LastQty : float typ
module LastQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = LastQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 32
    let name = "LastQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | LastQty, LastQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module LastQty)

type _ typ += MaxShow : float typ
module MaxShow = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = MaxShow
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 210
    let name = "MaxShow"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MaxShow, MaxShow -> Some Eq
      | _ -> None
  end)
let () = register_field (module MaxShow)

type _ typ += StrikePrice : float typ
module StrikePrice = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = StrikePrice
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 202
    let name = "StrikePrice"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | StrikePrice, StrikePrice -> Some Eq
      | _ -> None
  end)
let () = register_field (module StrikePrice)

type _ typ += MDEntryPx : float typ
module MDEntryPx = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = MDEntryPx
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 270
    let name = "MDEntryPx"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDEntryPx, MDEntryPx -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDEntryPx)

type _ typ += UnderlyingPx : float typ
module UnderlyingPx = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = UnderlyingPx
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 810
    let name = "UnderlyingPx"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | UnderlyingPx, UnderlyingPx -> Some Eq
      | _ -> None
  end)
let () = register_field (module UnderlyingPx)

type _ typ += UnderlyingEndPrice : float typ
module UnderlyingEndPrice = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = UnderlyingEndPrice
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 883
    let name = "UnderlyingEndPrice"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | UnderlyingEndPrice, UnderlyingEndPrice -> Some Eq
      | _ -> None
  end)
let () = register_field (module UnderlyingEndPrice)

type _ typ += SettlPrice : float typ
module SettlPrice = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = SettlPrice
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 730
    let name = "SettlPrice"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SettlPrice, SettlPrice -> Some Eq
      | _ -> None
  end)
let () = register_field (module SettlPrice)

type _ typ += MDEntrySize : float typ
module MDEntrySize = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = MDEntrySize
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 271
    let name = "MDEntrySize"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MDEntrySize, MDEntrySize -> Some Eq
      | _ -> None
  end)
let () = register_field (module MDEntrySize)

type _ typ += MinTradeVol : float typ
module MinTradeVol = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = MinTradeVol
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 562
    let name = "MinTradeVol"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MinTradeVol, MinTradeVol -> Some Eq
      | _ -> None
  end)
let () = register_field (module MinTradeVol)

type _ typ += ContractMultiplier : float typ
module ContractMultiplier = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = ContractMultiplier
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 231
    let name = "ContractMultiplier"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | ContractMultiplier, ContractMultiplier -> Some Eq
      | _ -> None
  end)
let () = register_field (module ContractMultiplier)

type _ typ += LongQty : float typ
module LongQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = LongQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 704
    let name = "LongQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | LongQty, LongQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module LongQty)

type _ typ += ShortQty : float typ
module ShortQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = ShortQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 705
    let name = "ShortQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | ShortQty, ShortQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module ShortQty)

type _ typ += LeavesQty : float typ
module LeavesQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = LeavesQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 151
    let name = "LeavesQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | LeavesQty, LeavesQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module LeavesQty)

type _ typ += CumQty : float typ
module CumQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = CumQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 14
    let name = "CumQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | CumQty, CumQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module CumQty)

type _ typ += OrderQty : float typ
module OrderQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = OrderQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 38
    let name = "OrderQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OrderQty, OrderQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module OrderQty)

type _ typ += CashOrderQty : float typ
module CashOrderQty = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = CashOrderQty
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 152
    let name = "CashOrderQty"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | CashOrderQty, CashOrderQty -> Some Eq
      | _ -> None
  end)
let () = register_field (module CashOrderQty)

type _ typ += MiscFeeAmt : float typ
module MiscFeeAmt = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = MiscFeeAmt
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 137
    let name = "MiscFeeAmt"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MiscFeeAmt, MiscFeeAmt -> Some Eq
      | _ -> None
  end)
let () = register_field (module MiscFeeAmt)

type _ typ += MinPriceIncrement : float typ
module MinPriceIncrement = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = MinPriceIncrement
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 969
    let name = "MinPriceIncrement"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | MinPriceIncrement, MinPriceIncrement -> Some Eq
      | _ -> None
  end)
let () = register_field (module MinPriceIncrement)

type _ typ += OpenInterest : float typ
module OpenInterest = Make(struct
    type t = float [@@deriving sexp,yojson]
    let t = OpenInterest
    let pp = Format.pp_print_float
    let parse = float_of_string_result
    let tag = 746
    let name = "OpenInterest"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | OpenInterest, OpenInterest -> Some Eq
      | _ -> None
  end)
let () = register_field (module OpenInterest)

type _ typ += StrikeCurrency : string typ
module StrikeCurrency = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = StrikeCurrency
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 947
    let name = "StrikeCurrency"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | StrikeCurrency, StrikeCurrency -> Some Eq
      | _ -> None
  end)
let () = register_field (module StrikeCurrency)

type _ typ += Currency : string typ
module Currency = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = Currency
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 15
    let name = "Currency"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | Currency, Currency -> Some Eq
      | _ -> None
  end)
let () = register_field (module Currency)

type _ typ += SettlType : string typ
module SettlType = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SettlType
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 63
    let name = "SettlType"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SettlType, SettlType -> Some Eq
      | _ -> None
  end)
let () = register_field (module SettlType)

type _ typ += SettlCurrency : string typ
module SettlCurrency = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SettlCurrency
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 120
    let name = "SettlCurrency"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SettlCurrency, SettlCurrency -> Some Eq
      | _ -> None
  end)
let () = register_field (module SettlCurrency)

type _ typ += CommCurrency : string typ
module CommCurrency = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = CommCurrency
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 479
    let name = "CommCurrency"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | CommCurrency, CommCurrency -> Some Eq
      | _ -> None
  end)
let () = register_field (module CommCurrency)

type _ typ += SecurityExchange : string typ
module SecurityExchange = Make(struct
    type t = string [@@deriving sexp,yojson]
    let t = SecurityExchange
    let pp = Format.pp_print_string
    let parse s = Ok s
    let tag = 207
    let name = "SecurityExchange"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | SecurityExchange, SecurityExchange -> Some Eq
      | _ -> None
  end)
let () = register_field (module SecurityExchange)

type _ typ += AggressorIndicator : bool typ
module AggressorIndicator = Make(struct
    type t = bool [@@deriving sexp,yojson]
    let t = AggressorIndicator
    let pp = YesOrNo.pp
    let parse = YesOrNo.parse
    let tag = 1057
    let name = "AggressorIndicator"
    let eq :
      type a b. a typ -> b typ -> (a, b) eq option = fun a b ->
      match a, b with
      | AggressorIndicator, AggressorIndicator -> Some Eq
      | _ -> None
  end)
let () = register_field (module AggressorIndicator)

(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)

