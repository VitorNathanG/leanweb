import LeanWeb.Server
import Std.Sync.Mutex

open LeanWeb

-- Test-only effects and self-process diagnostics; never exposed by the example server.
def main (args : List String) : IO Unit := do
  let [port] := args | throw (IO.userError "Expected test port")
  let some port := port.toNat? | throw (IO.userError "Invalid test port")
  let effects ← Std.Mutex.new (0 : Nat)
  Server.serve (fun request => do
    match request.path with
    | "/touch" =>
      effects.atomically (modify (· + 1))
      return .text "touched"
    | "/effects" => return .text (toString (← effects.atomically get))
    | "/throw" => throw (IO.userError "test-only secret exception")
    | "/slow-handler" =>
      effects.atomically (modify (· + 1))
      IO.println "slow-handler-start"
      (← IO.getStdout).flush
      IO.sleep 600
      return .text "finished"
    | "/large" =>
      return .text ("".pushn 'x' (16 * 1024 * 1024))
    | "/fds" =>
      let entries ← System.FilePath.readDir "/proc/self/fd"
      return .text (toString entries.size)
    | _ => return .text "ok")
    { port := port.toUInt16, maxConnections := 2, requestTimeoutMs := 200 }
