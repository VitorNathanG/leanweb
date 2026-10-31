-- Inserted after the unchanged LeanHttp.Server IO helpers by prepare.mjs.
private def sendValue (channel : Std.CloseableChannel α) (value : α) : IO Unit := do
  match ← IO.wait (← channel.send value) with
  | .ok () => pure ()
  | .error _ => throw (IO.userError "Worker channel closed")

private def pooledWorker (inbox : Std.CloseableChannel (Socket × Nat))
    (available : Std.CloseableChannel (Std.CloseableChannel (Socket × Nat)))
    (handler : Request → IO Response) (config : Config) : IO Unit := do
  repeat
    sendValue available inbox
    let some (socket, deadline) ← IO.wait (← inbox.recv) | return
    try respond socket handler config deadline
    catch _ => pure ()

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
  let available ← Std.CloseableChannel.new (some config.maxConnections)
  let mut inboxes : List (Std.CloseableChannel (Socket × Nat)) := []
  let mut workers : List (Task (Except IO.Error Unit)) := []
  try
    for _ in [:config.maxConnections] do
      let inbox ← Std.CloseableChannel.new (some 1)
      inboxes := inbox :: inboxes
      let worker ← IO.asTask (pooledWorker inbox available handler config) .dedicated
      workers := worker :: workers
    repeat
      let some inbox ← IO.wait (← available.recv)
        | throw (IO.userError "No available worker channel")
      let socket ← await listener.accept
      let deadline := (← IO.monoMsNow) + config.requestTimeoutMs.toNat
      sendValue inbox (socket, deadline)
  finally
    for inbox in inboxes do discard <| inbox.close.toBaseIO
    for worker in workers do discard <| IO.wait worker
