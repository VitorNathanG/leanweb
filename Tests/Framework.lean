import LeanWeb

open LeanHttp LeanWeb

namespace Tests.Framework

deriving instance DecidableEq for Except

private def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"Decoder test failed: {label}")

private def request (body : String) (query : String := "by=5") : Request :=
  { method := .post, path := "/divide", body, query }

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
  IO.println "Framework tests passed"

end Tests.Framework
