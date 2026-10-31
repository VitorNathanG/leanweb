import Example

open LeanHttp LeanWeb

namespace Tests.Application

private def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"Application test failed: {label}")

private def request (body : String) (query : String := "by=5") : Request :=
  { method := .post, path := "/divide", body, query }

-- These examples are kernel-checked during the build, not merely runtime assertions.
example : (Example.routes.routes.map Route.key).Nodup := Example.routes.unique

example (request : Request) : (Example.echo.run request).body = request.body :=
  (Example.echo.ensures request).2

example : (⟨.get, "/health"⟩ : RouteKey) ∈ Example.routes.routes.map Route.key := by decide

example : ¬ (⟨.get, "/health"⟩ : RouteKey) ∉ Example.routes.routes.map Route.key := by decide

-- Successful decoding retains the source relation, not just the range check.
example (req : Request) (input : Nat × Nat)
    (decoded : Example.divisionDecoder.decode req = .ok input) :
    req.body.toNat? = some input.1 ∧ 0 < input.2 :=
  ⟨(Example.divisionDecoder.sound req input decoded).1.1,
    (Example.divisionDecoder.sound req input decoded).2.1⟩

example (req : Request) (input : Nat × Nat) (pre : Example.divisionPre req input) :
    ∃ quotient remainder,
      Example.divisionController.run req input pre = Example.divisionResult quotient remainder ∧
      input.2 * quotient + remainder = input.1 ∧ remainder < input.2 :=
  Example.divisionController.ensures req input pre

example (req : Request) (error : DecodeError)
    (failed : Example.divisionDecoder.decode req = .error error) :
    Example.division.run req = error.toResponse :=
  Example.divisionDecoder.handle_error _ _ req error failed

def run : IO Unit := do
  for (body, query, quotient, remainder) in [
      ("17", "by=5", 3, 2), ("0", "by=1", 0, 0), ("1", "by=2", 0, 1),
      ("1000000", "by=1", 1000000, 0), ("1000000", "by=1000000", 1, 0)] do
    check (Example.division.run (request body query) == Example.divisionResult quotient remainder)
      "verified division result and inclusive bounds"
  for (body, query) in [("17", "by=0"), ("1000001", "by=1"), ("17", "by=1000001"),
      ("bad", "by=5"), ("17", ""), ("17", "by=5&by=5")] do
    check ((Example.division.run (request body query)).status == .badRequest)
      "invalid division returns 400"

  let calls ← IO.mkRef (0 : Nat)
  let effectful : Handler (IO Response) := Example.divisionDecoder.handle
    (fun error => pure error.toResponse)
    (fun _ input _ => do
      calls.modify (· + 1)
      return Example.divisionResult (input.1 / input.2) (input.1 % input.2))
  for req in [request "bad", request "17" "", request "17" "by=0",
      request "17" "by=5&by=5", request "1000001"] do
    check ((← effectful req).status == .badRequest) "effectful controller rejection"
  check ((← calls.get) == 0) "parse and validation failures never run the controller"
  check ((← effectful (request "17")) == Example.divisionResult 3 2) "effectful controller success"
  check ((← calls.get) == 1) "valid request runs controller exactly once"
  let services : Example.Services := { greeting := pure "unused" }
  check ((← Example.app.handle services (request "17")) == Example.divisionResult 3 2)
    "typed controller registered in application"
  check ((← Example.app.handle services (request "17" "by=0")).status == .badRequest)
    "application preserves decoding rejection"
  IO.println "Decoder and typed controller tests passed"

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

end Tests.Application
