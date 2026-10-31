import Std

/-! Exercise runtime task waits, promise completion, and cancellation with shared and disjoint waiters. -/

set_option autoImplicit false

private def check (condition : Bool) (message : String) : IO Unit := do
  unless condition do throw (IO.userError message)

@[noinline] private def abandoned : IO (Task (Option Nat)) := do
  return (← IO.Promise.new).result?

private def completed : IO Unit := do
  let a ← IO.Promise.new
  let b ← IO.Promise.new
  a.resolve 11
  b.resolve 22
  check ((← IO.wait a.result?) == some 11) "completed wait"
  check ((← IO.waitAny [a.result?, b.result?] (by simp)) == some 11) "waitAny list order"
  check ((← IO.wait (← abandoned)) == none) "abandoned producer"

private def shared (round : Nat) : IO Unit := do
  let promise : IO.Promise Nat ← IO.Promise.new
  let other : IO.Promise Nat ← IO.Promise.new
  let mut workers := #[]
  for i in [:24] do
    let ready ← IO.Promise.new
    let worker ← IO.asTask (prio := .dedicated) do
      ready.resolve ()
      let value ← if i % 2 == 0 then IO.wait promise.result? else
        IO.waitAny [other.result?, promise.result?, promise.result?] (by simp)
      check (value == some round) "shared or duplicate wait"
    discard <| IO.wait ready.result?
    workers := workers.push worker
  IO.sleep 1
  promise.resolve round
  for worker in workers do
    match ← IO.wait worker with
    | .ok () => pure ()
    | .error error => throw error
  other.resolve (round + 1)

private def raced (round : Nat) : IO Unit := do
  let a : IO.Promise Nat ← IO.Promise.new
  let b : IO.Promise Nat ← IO.Promise.new
  let worker ← IO.asTask (prio := .dedicated) do
    let value ← IO.waitAny [a.result?, b.result?] (by simp)
    check (value == some round || value == some (round + 1)) "raced waitAny"
  let producer ← IO.asTask (prio := .dedicated) do a.resolve round
  b.resolve (round + 1)
  for task in [worker, producer] do
    match ← IO.wait task with
    | .ok () => pure ()
    | .error error => throw error

private def disjoint : IO Unit := do
  let waiting : IO.Promise Nat ← IO.Promise.new
  let ready ← IO.Promise.new
  let worker ← IO.asTask (prio := .dedicated) do
    ready.resolve ()
    check ((← IO.wait waiting.result?) == some 7) "unrelated completion"
  discard <| IO.wait ready.result?
  for i in [:100] do
    let noise ← IO.Promise.new
    noise.resolve i
    check ((← IO.wait noise.result?) == some i) "noise"
  check (!(← IO.hasFinished worker)) "unrelated task released waiter"
  waiting.resolve 7
  match ← IO.wait worker with
  | .ok () => pure ()
  | .error error => throw error

private def cancellation : IO Unit := do
  let gate : IO.Promise Unit ← IO.Promise.new
  let ready ← IO.Promise.new
  let worker ← IO.asTask (prio := .dedicated) do
    ready.resolve ()
    discard <| IO.wait gate.result?
    check (← IO.checkCanceled) "cooperative cancellation flag"
  discard <| IO.wait ready.result?
  IO.cancel worker
  gate.resolve ()
  match ← IO.wait worker with
  | .ok () => pure ()
  | .error error => throw error

@[noinline] private def heldPromise : IO (IO.Ref (Option (IO.Promise Nat)) × Task (Option Nat)) := do
  let producer ← IO.Promise.new
  return (← IO.mkRef (some producer), producer.result?)

private def pendingAbandonment : IO Unit := do
  let (holder, pending) ← heldPromise
  let other : IO.Promise Nat ← IO.Promise.new
  let ready ← IO.Promise.new
  let worker ← IO.asTask (prio := .dedicated) do
    ready.resolve ()
    check ((← IO.waitAny [pending, other.result?] (by simp)) == none) "pending producer dropped"
  discard <| IO.wait ready.result?
  IO.sleep 1
  holder.set none
  match ← IO.wait worker with
  | .ok () => pure ()
  | .error error => throw error
  other.resolve 1

private def standardPool : IO Unit := do
  let gate : IO.Promise Nat ← IO.Promise.new
  let mut workers := #[]
  for _ in [:8] do
    let worker ← IO.asTask do
      check ((← IO.wait gate.result?) == some 9) "standard-pool wait"
    workers := workers.push worker
  IO.sleep 1
  let producer ← BaseIO.asTask (gate.resolve 9)
  discard <| IO.wait producer
  for worker in workers do
    match ← IO.wait worker with
    | .ok () => pure ()
    | .error error => throw error

private def dependencies : IO Unit := do
  let promise : IO.Promise Nat ← IO.Promise.new
  let mapped ← BaseIO.mapTask (fun value => pure (value.getD 0 + 1)) promise.result? (sync := true)
  let bound ← BaseIO.bindTask mapped (fun value => pure (Task.pure (value + 1))) (sync := true)
  promise.resolve 40
  check ((← IO.wait bound) == 42) "synchronous dependency chain"

def main (args : List String) : IO Unit := do
  if args == ["shutdown"] then
    for _ in [:8] do
      discard <| IO.asTask (prio := .dedicated) do
        repeat
          if ← IO.checkCanceled then return
          IO.sleep 1
    IO.println "Shutdown workers started"
    return
  completed
  disjoint
  cancellation
  pendingAbandonment
  standardPool
  dependencies
  for round in [:30] do shared round
  for round in [:1000] do raced round
  IO.println "Task wait regressions passed"
