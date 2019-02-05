open Core
open Async

open Bs_devkit
open Fix
open Fixtypes
open Deribit

let src = Logs.Src.create "fix.deribit.shell"
let uri = Uri.make ~host:"test.deribit.com" ~port:9881 ()

let hb msg =
  Fix.create ~fields:[Field.TestReqID.create msg] MsgType.Heartbeat

let on_server_msg _w msg = match msg.Fix.typ with
  | _ -> Deferred.unit

let on_client_cmd username w words =
  let words = String.split ~on:' ' @@ String.chop_suffix_exn words ~suffix:"\n" in
  match words with
  | "testreq" :: _ ->
    let fields = [Field.TestReqID.create "a"] in
    Pipe.write w (Fix.create ~fields MsgType.TestRequest)
  | "seclist" :: _ ->
    let fields = [
      Field.SecurityReqID.create "a" ;
      Field.SecurityListRequestType.create Symbol ;
    ] in
    Pipe.write w (Fix.create ~fields MsgType.SecurityListRequest)
  | "snapshot" :: symbol :: _ ->
    let fields = [
      Field.Symbol.create symbol ;
      Field.MDReqID.create "a" ;
      Field.SubscriptionRequestType.create Snapshot ;
      Field.MarketDepth.create 0 ;
    ] in
    let groups =
      Field.NoMDEntryTypes.create 3, [
        [ Field.MDEntryType.create Bid ] ;
        [ Field.MDEntryType.create Offer ] ;
        [ Field.MDEntryType.create Trade ] ;
      ] in
    Pipe.write w (Fix.create ~groups ~fields MsgType.MarketDataRequest)
  | "positions" :: _ ->
    let fields = [
      Field.PosReqID.create "a" ;
      Field.PosReqType.create Positions ;
      Field.SubscriptionRequestType.create Snapshot ;
    ] in
    Pipe.write w (Fix.create ~fields MsgType.RequestForPositions)
  | "info" :: _ ->
    let fields = [
      Field.UserRequestID.create "a" ;
      Field.UserRequestType.create RequestStatus ;
      Field.Username.create username ;
    ] in
    Pipe.write w (Fix.create ~fields MsgType.UserRequest)
  | "buy" :: symbol :: _ ->
    let fields = [
      Field.ClOrdID.create Uuid.(create () |> to_string) ;
      Field.Side.create Buy ;
      Field.OrderQty.create 1. ;
      Field.OrdType.create Market ;
      Field.Symbol.create symbol ;
    ] in
    Pipe.write w (Fix.create ~fields MsgType.NewOrderSingle)
  | "sell" :: symbol :: _ ->
    let fields = [
      Field.ClOrdID.create Uuid.(create () |> to_string) ;
      Field.Side.create Sell ;
      Field.OrderQty.create 1. ;
      Field.OrdType.create Market ;
      Field.Symbol.create symbol ;
    ] in
    Pipe.write w (Fix.create ~fields MsgType.NewOrderSingle)
  | _ ->
    Logs_async.app ~src (fun m -> m "Unsupported command")

let main cfg =
  Logs_async.debug ~src (fun m -> m "%a" Cfg.pp cfg) >>= fun () ->
  let { Cfg.key ; secret ; _ } =
    List.Assoc.find_exn ~equal:String.equal cfg "DERIBIT" in
  let ts = Ptime_clock.now () in
  let logon_fields =
    logon_fields ~cancel_on_disconnect:true ~username:key ~secret ~ts in
  Fix_async.with_connection_ez
    ~sid ~tid ~version:Version.v44 ~logon_fields uri >>= fun (closed, r, w) ->
  Signal.(handle terminating ~f:(fun _ -> Pipe.close w)) ;
  Logs_async.app ~src (fun m -> m "Connected to Deribit") >>= fun () ->
  Deferred.any [
    Pipe.iter r ~f:(on_server_msg w);
    Pipe.iter Reader.(stdin |> Lazy.force |> pipe) ~f:(on_client_cmd key w);
    closed
  ]

let command =
  Command.async ~summary:"Deribit testnet shell" begin
    let open Command.Let_syntax in
    [%map_open
      let cfg = Cfg.param ()
      and () = Logs_async_reporter.set_level_via_param None in
      fun () ->
        Logs.set_reporter (Logs_async_reporter.reporter ()) ;
        main cfg
    ]
  end

let () = Command.run command