import Std.Internal.UV.TCP
import Std.Internal.UV.Timer

open Std.Internal.UV
open Std.Internal.UV.TCP

abbrev ReadResult := Option (Except IO.Error (Option ByteArray))

def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

-- Keep result tasks only. The noinline boundary makes producer lifetime explicit.
@[noinline] def readTask (socket : Socket) : IO (Task ReadResult) := do
  return (← socket.recv? 8).result?

@[noinline] def timerTask (timer : Timer) : IO (Task (Option Unit)) := do
  return (← timer.next).result?

@[noinline] def operationTask (operation : IO (IO.Promise (Except IO.Error α))) :
    IO (Task (Option (Except IO.Error α))) := do
  return (← operation).result?

def awaitOperation (operation : IO (IO.Promise (Except IO.Error α))) : IO α := do
  match (← operationTask operation).get with
  | some (.ok value) => return value
  | some (.error e) => throw e
  | none => throw (IO.userError "unexpected dropped operation")

def isData : ReadResult → Bool
  | some (.ok (some bytes)) => bytes == "x".toUTF8
  | _ => false

def isCancelled : ReadResult → Bool
  | none => true
  | _ => false

@[noinline] def withPair (listener : Socket) (action : Socket → Socket → IO α) : IO α := do
  let peer ← Socket.new
  awaitOperation (peer.connect (← listener.getSockName))
  let socket ← awaitOperation listener.accept
  try
    let result ← action socket peer
    -- These IO uses keep both endpoints alive throughout assertions and sender joins.
    discard <| peer.getSockName
    discard <| socket.getSockName
    return result
  finally
    socket.cancelRecv
    -- No shutdown: only finalizer close after all successful sends were awaited.

def checkpoint (name : String) : IO Unit := do
  IO.sleep 50
  IO.println s!"CHECKPOINT {name}"
  IO.sleep 50

def pending (listener : Socket) : IO Unit := do
  for _ in [:100] do
    withPair listener fun socket _ => do
      let task ← readTask socket
      IO.sleep 1
      check (!(← IO.hasFinished task)) "pending read unexpectedly finished"
      socket.cancelRecv
      socket.cancelRecv
      socket.cancelRecv
      check (isCancelled task.get) "pending cancellation was not outer none"
  IO.println "RESULT pending iterations=100 outer_none=100 repeated_cancel_calls=300"

def completionRace (listener : Socket) : IO Unit := do
  let mut data := 0
  let mut cancelled := 0
  for i in [:100] do
    let outcome ← withPair listener fun socket peer => do
      let task ← readTask socket
      let sender ← IO.asTask do
        IO.sleep (i % 3).toUInt32
        awaitOperation (peer.send #["x".toUTF8])
      IO.sleep ((i + 1) % 3).toUInt32
      socket.cancelRecv
      socket.cancelRecv
      IO.ofExcept sender.get
      let outcome := task.get
      check (isCancelled outcome || isData outcome) "race: unexpected EOF/error/payload"
      return isData outcome
    if outcome then data := data + 1 else cancelled := cancelled + 1
  check (data > 0 && cancelled > 0) "race schedule did not cover both outcomes"
  IO.println s!"RESULT completion_race iterations=100 data={data} outer_none={cancelled}"

def timerLifecycle : IO Unit := do
  for _ in [:100] do
    let timer ← Timer.mk 1000 false
    try
      let first ← timerTask timer
      check (!(← IO.hasFinished first)) "long timer unexpectedly ready"
      timer.cancel
      timer.cancel
      check first.get.isNone "cancelled timer did not drop first promise"
      let second ← timerTask timer
      check (!(← IO.hasFinished second)) "cancelled one-shot failed to restart"
      timer.cancel
      check second.get.isNone "cancelled timer did not drop second promise"
    finally timer.cancel
    let timer ← Timer.mk 1 false
    try
      check (← timerTask timer).get.isSome "one-shot did not fire"
      timer.cancel
      check (← timerTask timer).get.isSome "finished one-shot lost its result"
    finally timer.cancel
  IO.println "RESULT timer_lifecycle iterations=100 cancelled_promises=200 fired=100 finished_result_preserved=100"

inductive Event where
  | receive (result : ReadResult)
  | timer (result : Option Unit)

-- mode 0: silent peer; mode 1: fast read; mode 2: near-completion race.
def selection (listener : Socket) (mode : Nat) : IO Unit := do
  let mut reads := 0
  let mut timeouts := 0
  let mut readCancelled := 0
  let mut timerCancelled := 0
  for i in [:100] do
    let (readWon, cancelledRead, cancelledTimer) ← withPair listener fun socket peer => do
      let timer ← Timer.mk (if mode == 1 then 1000 else if mode == 0 then 2 else 1) false
      try
        let recv ← readTask socket
        let tick ← timerTask timer
        let sender ← if mode == 0 then pure none else do
          let sender ← IO.asTask do
            IO.sleep (if mode == 1 then 0 else (i % 3).toUInt32)
            awaitOperation (peer.send #["x".toUTF8])
          pure (some sender)
        let events := [recv.map Event.receive (sync := true), tick.map Event.timer (sync := true)]
        let winner ← IO.waitAny events
        let readWon ← match winner with
          | .receive value => do
            check (isData value) "selected receive was not data"
            pure true
          | .timer value => do
            check value.isSome "selected timer was cancelled before cleanup"
            pure false
        socket.cancelRecv
        timer.cancel
        -- Cleanup is idempotent; both result tasks must become observable.
        socket.cancelRecv
        timer.cancel
        let readResult := recv.get
        let timerResult := tick.get
        check (isCancelled readResult || isData readResult) "selection: EOF/error/bad payload"
        if let some sender := sender then IO.ofExcept sender.get
        return (readWon, isCancelled readResult, timerResult.isNone)
      finally
        socket.cancelRecv
        timer.cancel
    if readWon then reads := reads + 1 else timeouts := timeouts + 1
    if cancelledRead then readCancelled := readCancelled + 1
    if cancelledTimer then timerCancelled := timerCancelled + 1
  if mode == 0 then check (timeouts == 100 && readCancelled == 100) "silent peers did not time out"
  if mode == 1 then check (reads == 100 && timerCancelled == 100) "fast reads failed timer cleanup"
  IO.println s!"RESULT selection mode={mode} iterations=100 read_wins={reads} timer_wins={timeouts} read_outer_none={readCancelled} timer_outer_none={timerCancelled}"

def main : IO Unit := do
  let start ← IO.monoMsNow
  let listener ← Socket.new
  let some host := Std.Net.IPv4Addr.ofString "127.0.0.1"
    | throw (IO.userError "invalid probe loopback literal")
  listener.bind (.v4 { addr := host, port := 0 })
  listener.listen 4
  IO.println "PROBE receive-deadline v1 iterations=100 recv_cap=8 send_bytes=1 loopback=127.0.0.1 port=ephemeral"
  -- Warm up libuv's lazy descriptor allocation before baseline accounting.
  withPair listener fun _ _ => pure ()
  checkpoint "baseline"
  pending listener
  checkpoint "pending"
  completionRace listener
  checkpoint "completion_race"
  timerLifecycle
  checkpoint "timer_lifecycle"
  selection listener 0
  checkpoint "silent_selection"
  selection listener 1
  checkpoint "read_selection"
  selection listener 2
  checkpoint "raced_selection"
  IO.println s!"PASS elapsed_ms={(← IO.monoMsNow) - start}"
