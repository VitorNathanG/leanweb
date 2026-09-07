import LeanWeb.Example

namespace LeanWeb.DecodingTests

deriving instance DecidableEq for Except

private def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"Decoder test failed: {label}")

private def request (body : String) (query : String := "by=5") : Request :=
  { method := .post, path := "/divide", body, query }

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
  for (text, expected) in [("0", 0), ("17", 17), ("00017", 17),
      ("99999999999999999999", 99999999999999999999)] do
    check (decide (Decoder.bodyNat.decode (request text) = .ok expected)) s!"decimal {text}"
  for text in ["", "-1", "+1", " 1", "1 ", "1\n", "1\t", "1.0", "1e2", "0x10", "1_000",
      "_1", "1_", "1__0", "123456789012345678901", String.singleton (Char.ofNat 0x0661),
      String.singleton (Char.ofNat 0xff11), String.singleton (Char.ofNat 0)] do
    check (decide (Decoder.bodyNat.decode (request text) = .error (.invalid "body")))
      s!"reject non-decimal or overlong body: {repr text}"
  let limited := Decoder.nat (fun req => .ok req.body) "number" 2
  check (decide (limited.decode (request "99") = .ok 99)) "configured digit limit inclusive"
  check (decide (limited.decode (request "100") = .error (.invalid "number")))
    "configured digit limit exceeded"
  let absent := Decoder.nat (fun _ => .error (.missing "source")) "number"
  check (decide (absent.decode (request "1") = .error (.missing "source"))) "source error preserved"

  for (query, expected) in [("by=5", 5), ("by=0005", 5), ("other=9&by=5", 5),
      ("by=5&other=9", 5), ("by=0", 0)] do
    check (decide ((Decoder.queryNat "by").decode (request "17" query) = .ok expected))
      "unique raw query parameter"
  for query in ["", "other=5", "BY=5", "%62y=5"] do
    check (decide ((Decoder.queryNat "by").decode (request "17" query) = .error (.missing "by")))
      "missing exact query key"
  for query in ["by=5&by=5", "by=5&by=0", "by=&by=5", "by=5&other=1&by=6"] do
    check (decide ((Decoder.queryNat "by").decode (request "17" query) = .error (.duplicate "by")))
      "duplicate query key rejected"
  for query in ["by", "=5", "by=5&", "&by=5", "by=5&&other=1", "by=5=6", "by=5&broken"] do
    check (decide ((Decoder.queryNat "by").decode (request "17" query) = .error (.invalid "query")))
      "malformed query rejected"
  for query in ["by=", "by=-1", "by=+1", "by=%35", "by=1.0", "by=1_0", "by=_1",
      "by=1_", "by=1__0", "by=123456789012345678901"] do
    check (decide ((Decoder.queryNat "by").decode (request "17" query) = .error (.invalid "by")))
      "invalid query number"

  let paired := Decoder.bodyNat.zip (Decoder.queryNat "by")
  check (decide (paired.decode (request "17") = .ok (17, 5))) "decoder composition"
  check (decide (paired.decode (request "bad" "") = .error (.invalid "body")))
    "left decoder error wins"
  check (decide (paired.decode (request "17" "") = .error (.missing "by")))
    "right decoder error preserved"
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

end LeanWeb.DecodingTests
