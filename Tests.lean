import LeanWeb
import LeanWeb.Example
import LeanWeb.WireTests
import LeanWeb.DecodingTests

open LeanWeb

private def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"Test failed: {label}")

-- These examples are kernel-checked during the build, not merely runtime assertions.
example : (Example.routes.routes.map Route.key).Nodup := Example.routes.unique

example (request : Request) : (Example.echo.run request).body = request.body :=
  (Example.echo.ensures request).2

example : (⟨.get, "/health"⟩ : RouteKey) ∈ Example.routes.routes.map Route.key := by decide

example : ¬ (⟨.get, "/health"⟩ : RouteKey) ∉ Example.routes.routes.map Route.key := by decide

def main : IO Unit := do
  WireTests.run
  DecodingTests.run
  let calls ← IO.mkRef (0 : Nat)
  let services : Example.Services := { greeting := do
    calls.modify (· + 1)
    pure "Injected greeting\n" }
  let handle := Example.app.handle services
  let response ← handle { method := .get, path := "/" }
  check (response.body == "Injected greeting\n") "dependency injection"
  check ((← calls.get) == 1) "injected effect executed once"
  let response ← handle { method := .get, path := "/health", query := "verbose=true" }
  check (response == .json "{\"status\":\"ok\"}") "health route ignores query"
  let response ← handle { method := .post, path := "/echo", body := "round trip" }
  check (response == .text "round trip") "verified echo"
  for request in [
      { method := .get, path := "/missing" : Request },
      { method := .get, path := "/echo" : Request },
      { method := .post, path := "/health" : Request },
      { method := .get, path := "/health/" : Request }] do
    check ((← handle request).status == .notFound) "exact method/path matching"
  let oversized := String.ofList (List.replicate 65537 'a')
  let response ← handle { method := .get, path := "/", body := oversized }
  check (response.status == .payloadTooLarge) "application body limit"
  check ((← calls.get) == 1) "denied requests do not execute injected effects"
  let boundary := String.ofList (List.replicate 65536 'a')
  let response ← handle { method := .post, path := "/echo", body := boundary }
  check (response.body == boundary && response.status == .ok) "inclusive body limit"
  let multibyte := String.ofList (List.replicate 32768 (Char.ofNat 0x3bb))
  let response ← handle { method := .post, path := "/echo", body := multibyte }
  check (response.body == multibyte && response.status == .ok) "multibyte body at byte limit"
  let response ← handle { method := .post, path := "/echo", body := multibyte ++ "a" }
  check (response.status == .payloadTooLarge) "body limit counts bytes, not characters"
  let denied : Handler (IO Response) := fun _ => pure (.text "Denied" .forbidden)
  let exploding : Handler (IO Response) := fun _ => throw (IO.userError "must not run")
  let response ← Middleware.guard (fun _ => false) denied exploding { method := .get, path := "/" }
  check (response.status == .forbidden) "guard short-circuits IO"
  let mark (label : String) : Middleware (IO Response) := fun next request => do
    let response ← next request
    return { response with body := label ++ response.body }
  let response ← Middleware.compose (mark "outer:") (mark "inner:")
    (fun _ => pure (.text "handler")) { method := .get, path := "/" }
  check (response.body == "outer:inner:handler") "middleware composition order"
  let invoked ← IO.mkRef false
  let handler : Request → IO Response := fun _ => do
    invoked.set true
    return .text "handled"
  let rejected := Response.text "Incomplete request\n" .badRequest
  for parsed in [.error rejected, .ok { method := .get, path := "/" }] do
    let expired ← (Server.responseBeforeDeadline handler parsed 0).toBaseIO
    check (!expired.toBool) "expired parsed requests and rejections cannot select a response"
  check (!(← invoked.get)) "expired request cannot invoke handler"
  let accepted ← Server.responseBeforeDeadline handler (.error rejected) ((← IO.monoMsNow) + 1000)
  check (accepted == rejected) "ordinary pre-deadline rejection is preserved"
  for config in [
      { maxConnections := 0 : Server.Config },
      { requestTimeoutMs := 0 : Server.Config },
      { maxRequestBytes := 0 : Server.Config },
      { backlog := 0 : Server.Config },
      { backlog := 2147483648 : Server.Config },
      { host := "not-an-address" : Server.Config }] do
    let result ← (Server.serve exploding config).toBaseIO
    check (!result.toBool) "invalid server configuration fails before listening"
  IO.println "Core and application tests passed"
