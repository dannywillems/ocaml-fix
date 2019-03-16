(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Fix
open Fixtypes

val url : Uri.t
val sandbox_url : Uri.t
val tid : string

val logon_fields :
  ?cancel_on_disconnect:[`All | `Session] ->
  key:string ->
  secret:string ->
  passphrase:string ->
  logon_ts:Ptime.t -> Field.t list

val testreq : testreqid:string -> t
val order_status_request : ?orderID:string -> unit -> t

val new_order_market :
  clOrdID:Uuidm.t -> side:Side.t ->
  qty:float -> symbol:string -> t

val new_order_limit :
  clOrdID:Uuidm.t -> side:Side.t ->
  price:float -> qty:float ->
  timeInForce:TimeInForce.t -> symbol:string -> t

val cancel_order : srvOrdID:Uuidm.t -> t

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
