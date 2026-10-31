-- Inserted after the unchanged LeanHttp.Server IO helpers by prepare.mjs.
private structure ConnectionJob where
  socket : Socket
  deadline : Nat

private structure InboxState where
  pending : Option ConnectionJob := none
  closed : Bool := false

private structure Inbox where
  state : Std.Mutex InboxState
  changed : Std.Condvar

private def Inbox.new : IO Inbox := do
  return { state := ← Std.Mutex.new {}, changed := ← Std.Condvar.new }

private def Inbox.receive (inbox : Inbox) : IO (Option ConnectionJob) :=
  inbox.state.atomicallyOnce inbox.changed
    (do let state ← get; return state.closed || state.pending.isSome) do
    let state ← get
    set { state with pending := none }
    return state.pending

private def Inbox.deliver (inbox : Inbox) (job : ConnectionJob) : IO Unit :=
  inbox.state.atomically do
    let state ← get
    if state.closed || state.pending.isSome then
      throw (IO.userError "Worker inbox unavailable")
    set { state with pending := some job }
    inbox.changed.notifyOne

private def Inbox.close (inbox : Inbox) : IO Unit :=
  inbox.state.atomically do
    modify fun state => { state with closed := true }
    inbox.changed.notifyOne

private structure Available where
  state : Std.Mutex (List Inbox)
  changed : Std.Condvar

private def Available.new : IO Available := do
  return { state := ← Std.Mutex.new [], changed := ← Std.Condvar.new }

private def Available.put (available : Available) (inbox : Inbox) : IO Unit :=
  available.state.atomically do
    modify (inbox :: ·)
    available.changed.notifyOne

private def Available.take (available : Available) : IO Inbox :=
  available.state.atomicallyOnce available.changed (return !(← get).isEmpty) do
    let inbox :: rest ← get | throw (IO.userError "No available worker")
    set rest
    return inbox

private def pooledWorker (inbox : Inbox) (available : Available)
    (handler : Request → IO Response) (config : Config) : IO Unit := do
  repeat
    available.put inbox
    let some job ← inbox.receive | return
    try respond job.socket handler config job.deadline
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
  let available ← Available.new
  let mut inboxes : List Inbox := []
  let mut workers : List (Task (Except IO.Error Unit)) := []
  try
    for _ in [:config.maxConnections] do
      let inbox ← Inbox.new
      inboxes := inbox :: inboxes
      let worker ← IO.asTask (pooledWorker inbox available handler config) .dedicated
      workers := worker :: workers
    repeat
      let inbox ← available.take
      let socket ← await listener.accept
      let deadline := (← IO.monoMsNow) + config.requestTimeoutMs.toNat
      inbox.deliver { socket, deadline }
  finally
    for inbox in inboxes do inbox.close
    for worker in workers do discard <| IO.wait worker
