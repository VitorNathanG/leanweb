import LeanWeb.Wire
import Std.Internal.UV.TCP

namespace LeanWeb.Server

open Std.Internal.UV.TCP

structure Config where
  /-- Numeric IPv4 address; no DNS lookup. -/
  host : String := "127.0.0.1"
  port : UInt16 := 8080
  backlog : UInt32 := 128
  maxRequestBytes : Nat := Wire.defaultMaxRequestBytes
  deriving Repr

private def await (promise : IO.Promise (Except IO.Error α)) : IO α := do
  match promise.result?.get with
  | some (.ok value) => return value
  | some (.error error) => throw error
  | none => throw (IO.userError "TCP operation was canceled")

private def respond (socket : Socket) (handler : Request → IO Response) (config : Config) :
    IO Unit := do
  let mut bytes := ByteArray.empty
  let mut response : Response := .text "Incomplete request\n" .badRequest
  let mut headOnly := false
  repeat
    headOnly := bytes.extract 0 5 == "HEAD ".toUTF8
    match Wire.parse bytes config.maxRequestBytes with
    | .error error =>
      response := error
      break
    | .ok (some request) =>
      headOnly := request.method == .head
      try
        response ← handler request
      catch _ =>
        response := .text "Internal server error\n" .internalServerError
      break
    | .ok none =>
      -- Never allocate beyond the aggregate limit, even for an unterminated header block.
      let size := min 4096 (config.maxRequestBytes - bytes.size)
      match ← await (← socket.recv? size.toUInt64) with
      | none => break
      | some chunk => bytes := bytes ++ chunk
  await (← socket.send (Wire.render response headOnly))

/--
Serve HTTP/1.1 sequentially, one request per connection, until an accept/listener error occurs.
Configuration errors and listener errors propagate. Connection I/O errors are isolated; handler
exceptions become 500 responses. Send and shutdown promises are awaited; socket lifetime is managed
by the UV binding's reference-counted finalizer (there is no explicit close in this API).

Reads have an aggregate byte cap. A completed request is answered immediately and the connection is
closed; later-arriving pipeline data is never handled. There is no TLS, concurrency, graceful-stop
API, or read/handler/write/shutdown timeout. A slow peer or handler can block this sequential server;
use only with trusted clients or behind a proxy that enforces deadlines.

In Lean 4.24, cancelRecv on a pending read decrements the raw C++ socket payload as a Lean object
(src/runtime/uv/tcp.cpp), which can crash libuv. Do not add receive cancellation without a runtime fix.
Shutdown only closes the write side and cannot safely substitute for receive cancellation.
-/
def serve (handler : Request → IO Response) (config : Config := {}) : IO Unit := do
  if config.maxRequestBytes == 0 || config.backlog == 0 || config.backlog.toNat > 2147483647 then
    throw (IO.userError "Request limit must be positive; backlog must be in 1..2147483647")
  let some address := Std.Net.IPv4Addr.ofString config.host
    | throw (IO.userError "Server host must be a numeric IPv4 address")
  let listener ← Socket.new
  listener.bind (.v4 { addr := address, port := config.port })
  listener.listen config.backlog
  repeat
    let socket ← await (← listener.accept)
    try
      respond socket handler config
    catch _ => pure ()
    finally
      try
        await (← socket.shutdown)
      catch _ => pure ()

end LeanWeb.Server
