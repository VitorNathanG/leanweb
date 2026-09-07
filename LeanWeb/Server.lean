import LeanWeb.Wire
import Std.Internal.UV.TCP
import Std.Internal.UV.Timer

namespace LeanWeb.Server

open Std.Internal.UV.TCP

structure Config where
  /-- Numeric IPv4 address; no DNS lookup. -/
  host : String := "127.0.0.1"
  port : UInt16 := 8080
  backlog : UInt32 := 128
  maxRequestBytes : Nat := Wire.defaultMaxRequestBytes
  /-- Active workers, including handlers and pending writes. Excess clients wait in the OS backlog. -/
  maxConnections : Nat := 32
  /-- Total time from accept to a parsed request, not an idle timeout refreshed by each fragment. -/
  requestTimeoutMs : UInt32 := 5000
  deriving Repr

-- Do not retain producer promises while waiting for cancellation to drop them.
@[noinline] private def resultTask (operation : IO (IO.Promise α)) : IO (Task (Option α)) := do
  return (← operation).result?

private def await (operation : IO (IO.Promise (Except IO.Error α))) : IO α := do
  match ← IO.wait (← resultTask operation) with
  | some (.ok value) => return value
  | some (.error error) => throw error
  | none => throw (IO.userError "TCP operation was canceled")

private def readRequest (socket : Socket) (config : Config) (deadline : Nat) :
    IO (Except Response Request × Bool) := do
  let timer ← Std.Internal.UV.Timer.mk (deadline - (← IO.monoMsNow)).toUInt64 false
  try
    let tick ← resultTask timer.next
    let timeout := tick.map (fun _ => Sum.inr ()) (sync := true)
    let mut bytes := ByteArray.empty
    repeat
      if (← IO.monoMsNow) >= deadline then
        throw (IO.userError "Request read deadline expired")
      let headOnly := bytes.extract 0 5 == "HEAD ".toUTF8
      match Wire.parse bytes config.maxRequestBytes with
      | .error error => return (.error error, headOnly)
      | .ok (some request) =>
        return (.ok request, request.method == .head)
      | .ok none =>
        let size := min 4096 (config.maxRequestBytes - bytes.size)
        let recv ← resultTask (socket.recv? size.toUInt64)
        try
          let event ← IO.waitAny [recv.map Sum.inl (sync := true), timeout]
          match event with
          | .inr () => throw (IO.userError "Request read deadline expired")
          | .inl (some (.ok (some chunk))) => bytes := bytes ++ chunk
          | .inl (some (.ok none)) =>
            return (.error (.text "Incomplete request\n" .badRequest), headOnly)
          | .inl (some (.error error)) => throw error
          | .inl none => throw (IO.userError "TCP receive was canceled")
        finally
          socket.cancelRecv
          -- A losing receive may already have completed. Either terminal outcome is valid.
          discard <| IO.wait recv
  finally
    timer.cancel

/-- Response-selection boundary shared by the transport and executable deadline regressions. -/
def responseBeforeDeadline (handler : Request → IO Response)
    (request : Except Response Request) (deadline : Nat) : IO Response := do
  -- Parsing and EOF handling count too, for rejection responses as well as handlers.
  if (← IO.monoMsNow) >= deadline then
    throw (IO.userError "Request read deadline expired")
  match request with
    | .error response => pure response
    | .ok request => do
      try handler request
      catch _ => pure (.text "Internal server error\n" .internalServerError)

private def respond (socket : Socket) (handler : Request → IO Response) (config : Config)
    (deadline : Nat) : IO Unit := do
  let (request, headOnly) ← readRequest socket config deadline
  let response ← responseBeforeDeadline handler request deadline
  await (socket.send #[Wire.render response headOnly])

/--
Serve one request per connection with at most `maxConnections` tracked dedicated workers.
At capacity, stop accepting until a worker finishes; excess clients wait in the OS backlog (which
may overflow), without an HTTP overload response. The absolute read deadline starts at accept,
not at the client's connect or while queued in the backlog. Expiry closes silently without a handler.

Each worker owns its socket and the only pending receive. Reads and timers are explicitly cancelled;
sends are awaited before dropping the socket for finalizer-based close. Do not call write-side
shutdown: its immediate-error path leaks references in the pinned runtime. No socket escapes a worker.
Connection errors are isolated; handler exceptions become sanitized 500 responses. Listener errors
propagate after draining tracked workers. There is no graceful-stop API or drain deadline.

Development-only: handlers and writes have no deadline and retain their slots until actually done.
They can exhaust capacity; arbitrary handler-created work is outside this admission bound. There is
no TLS or general resource-safety proof. Receive cancellation is qualified only on the pinned runtime.
-/
def serve (handler : Request → IO Response) (config : Config := {}) : IO Unit := do
  if config.maxRequestBytes == 0 || config.backlog == 0 || config.backlog.toNat > 2147483647 then
    throw (IO.userError "Request limit must be positive; backlog must be in 1..2147483647")
  if config.maxConnections == 0 || config.requestTimeoutMs == 0 then
    throw (IO.userError "Connection limit and request timeout must be positive")
  let some address := Std.Net.IPv4Addr.ofString config.host
    | throw (IO.userError "Server host must be a numeric IPv4 address")
  let listener ← Socket.new
  listener.bind (.v4 { addr := address, port := config.port })
  listener.listen config.backlog
  let mut workers : List (Task (Except IO.Error Unit)) := []
  try
    repeat
      workers ← workers.filterM fun worker => return !(← IO.hasFinished worker)
      if workers.length >= config.maxConnections then
        if h : workers.length > 0 then discard <| IO.waitAny workers h
        continue
      let socket ← await listener.accept
      let deadline := (← IO.monoMsNow) + config.requestTimeoutMs.toNat
      let worker ← IO.asTask (respond socket handler config deadline) .dedicated
      workers := worker :: workers
  finally
    for worker in workers do discard <| IO.wait worker

end LeanWeb.Server
