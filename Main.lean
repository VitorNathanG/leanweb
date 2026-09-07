import LeanWeb
import LeanWeb.Example

def main (args : List String) : IO UInt32 := do
  let port ← match args with
    | [] => pure 8080
    | [value] => do
      if !value.toList.all (fun c => '0' <= c && c <= '9') then
        throw (IO.userError "Usage: leanweb [port]")
      match value.toNat? with
      | some port =>
        if 0 < port && port <= 65535 then pure port
        else throw (IO.userError "Port must be in 1..65535")
      | none => throw (IO.userError "Usage: leanweb [port]")
    | _ => throw (IO.userError "Usage: leanweb [port]")
  let services : LeanWeb.Example.Services := {
    greeting := pure "LeanWeb: a small server with a verified core.\n" }
  IO.println s!"Starting LeanWeb on http://127.0.0.1:{port} (development server)"
  LeanWeb.Server.serve (LeanWeb.Example.app.handle services) { port := port.toUInt16 }
  return 0
