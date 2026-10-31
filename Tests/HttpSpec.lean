import LeanHttp.Spec
import LeanHttp.Wire

set_option autoImplicit false

open LeanHttp LeanHttp.Spec

namespace Tests.HttpSpec

private def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"HTTP specification test failed: {label}")

private def sameRequest (left right : Request) : Bool :=
  left.method == right.method && left.path == right.path && left.query == right.query &&
    left.headers == right.headers && left.body == right.body

private def verify {limit : Nat} {bytes : ByteArray} {outcome : Outcome}
    (_contract : RequestOutcome limit bytes outcome) : IO Unit := do
  match outcome, Wire.parse bytes limit with
  | .needMore, .ok none => pure ()
  | .rejected error, .error response =>
    check (response == error.response) s!"rejection {repr error}"
  | .complete expected, .ok (some actual) =>
    check (sameRequest actual expected) "decoded source fields"
  | _, actual => throw (IO.userError s!"Parser disagrees with specification: {repr actual}")

private def frame (text : String) : ByteArray := (text ++ "\r\n\r\n").toUTF8

private def headOf (text : String) : Head := { text, endPos := (frame text).size }

private def unicodeForm : RequestForm := {
  method := .post
  target := .origin "/raw%2Fpath" (some "x=a+b?c")
  fields := [
    { name := "hOsT", value := "localhost", leading := "\t", trailing := " \t" },
    { name := "Content-Length", value := "0006", leading := " " },
    { name := "X-Test", value := "a:b", leading := " " },
    { name := "X-Test", value := "λ", leading := " " }]
  body := "é😀" }

private def unicodeHead : Head := headOf
  "POST /raw%2Fpath?x=a+b?c HTTP/1.1\r\nhOsT:\tlocalhost \t\r\nContent-Length: 0006\r\nX-Test: a:b\r\nX-Test: λ"

set_option maxRecDepth 2048 in
private theorem unicodeContract :
    RequestOutcome unicodeForm.bytes.size unicodeForm.bytes (.complete unicodeForm.request) :=
  .framed (by decide) (by decide)
    (.header (head := unicodeHead) (by decide)
      (.complete (by decide) (by decide) ⟨unicodeForm, by decide, rfl, rfl⟩))

private theorem waitingMalformed : RequestOutcome 512 "not a request".toUTF8 .needMore :=
  .framed (by decide) (by decide) (.needMore (by decide) (by decide))

private theorem waitingCR : RequestOutcome 512 "\r".toUTF8 .needMore :=
  .framed (by decide) (by decide) (.needMore (by decide) (by decide))

private theorem zeroLimit : RequestOutcome 0 ByteArray.empty (.rejected .tooLarge) :=
  .framed (by decide) (by decide) (.exhausted (by decide) (by decide))

private theorem overflowBeforeSyntax : RequestOutcome 0 "\n".toUTF8 (.rejected .tooLarge) :=
  .tooLarge (by decide)

private theorem syntaxBeforeExhaustion : RequestOutcome 1 "\n".toUTF8 (.rejected .bareLF) :=
  .scan (by decide) (by decide)

private def twoByteHead : Head := headOf
  "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 2"

private def partialUTF8 : ByteArray := frame twoByteHead.text ++ ByteArray.mk #[195]

private theorem waitingUTF8 : RequestOutcome 512 partialUTF8 .needMore :=
  .framed (by decide) (by decide)
    (.header (head := twoByteHead) (by decide) (.needMore (by decide) (by decide) (by decide)))

private theorem notUTF8 (bytes : ByteArray) (invalid : ¬bytes.IsValidUTF8) : ¬UTF8 bytes := by
  rintro ⟨text, rfl⟩
  exact invalid text.isValidUTF8

private def oneByteHead : Head := headOf
  "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1"

private def invalidBody : ByteArray := frame oneByteHead.text ++ ByteArray.mk #[255]

private theorem invalidBodyContract : RequestOutcome 512 invalidBody (.rejected .bodyUTF8) :=
  .framed (by decide) (by decide)
    (.header (head := oneByteHead) (by decide)
      (.bodyUTF8 (by decide) (by decide) (by decide) (notUTF8 _ (by decide))))

private def trailingInvalidBody : ByteArray :=
  frame oneByteHead.text ++ ByteArray.mk #[255, 255]

private theorem trailingBeforeEncoding :
    RequestOutcome 512 trailingInvalidBody (.rejected .trailing) :=
  .framed (by decide) (by decide)
    (.header (head := oneByteHead) (by decide)
      (.trailing (by decide) (by decide) (by decide)))

private def invalidHeader : ByteArray :=
  "BAD HTTP/0\r\nX: ".toUTF8 ++ ByteArray.mk #[255] ++ "\r\n\r\n".toUTF8

private theorem encodingBeforeSyntax :
    RequestOutcome 512 invalidHeader (.rejected .headerUTF8) :=
  .framed (by decide) (by decide)
    (.headerUTF8 (endPos := invalidHeader.size) (by decide) (notUTF8 _ (by decide)))

private def headerRejection (text : String) (error : Rejection) (limit : Nat := 512) : IO Unit := do
  let bytes := frame text
  let head := headOf text
  if facts : bytes.size <= limit ∧ ChecksPass (scanChecks bytes) ∧
      head.Matches bytes ∧ FirstFailure (head.checks limit) error then
    verify (.framed facts.1 facts.2.1 (.header facts.2.2.1 (.rejected facts.2.2.2)))
  else
    throw (IO.userError s!"Invalid header specification fixture: {text}")

private def accepted (form : RequestForm) : IO Unit := do
  let limit := form.bytes.size
  let text := String.ofList (form.header.toList.take (form.header.toList.length - 4))
  let head := headOf text
  if facts : form.Valid limit ∧ ChecksPass (scanChecks form.bytes) ∧
      head.Matches form.bytes ∧ ChecksPass (head.checks limit) ∧ form.bytes.size = head.total then
    verify (.framed (Nat.le_refl _) facts.2.1
      (.header facts.2.2.1 (.complete facts.2.2.2.1 facts.2.2.2.2 ⟨form, facts.1, rfl, rfl⟩)))
  else
    throw (IO.userError "Invalid successful specification fixture")

private def invalidForm (form : RequestForm) (label : String) : IO Unit :=
  check (!(form.valid 512)) label

def run : IO Unit := do
  verify unicodeContract
  verify waitingMalformed
  verify waitingCR
  verify zeroLimit
  verify overflowBeforeSyntax
  verify syntaxBeforeExhaustion
  verify waitingUTF8
  verify invalidBodyContract
  verify trailingBeforeEncoding
  verify encodingBeforeSyntax
  let base : RequestForm := {
    method := .get, target := .origin "/" none, fields := [{ name := "Host", value := "a" }] }
  for method in [Method.get, .head, .post, .put, .patch, .delete, .options] do
    accepted { base with method }
  accepted unicodeForm
  accepted { base with method := .options, target := .asterisk }
  accepted { base with target := .origin "/" (some "") }
  accepted { base with fields := base.fields ++ [{ name := "Content-Length", value := "0" }] }
  accepted { base with
    target := .origin "/%zz\\<>" none, fields := [{ name := "Host", value := "[" }] }
  let body := "\uFEFF\r\n\x00"
  accepted { base with body, fields := base.fields ++ [
    { name := "Content-Length", value := toString body.toUTF8.size },
    { name := "Upgrade", value := "websocket" }] }
  invalidForm { base with target := .asterisk } "asterisk is OPTIONS-only"
  invalidForm { base with target := .origin "/path?query" none } "path ends before first question mark"
  invalidForm { base with target := .origin "/#fragment" none } "no fragment"
  invalidForm { base with fields := [] } "Host required"
  invalidForm { base with fields := base.fields ++ base.fields } "Host unique"
  invalidForm { base with fields := [{ name := "Host", value := " a" }] } "normalized field values"
  invalidForm { base with fields := [{ name := "Host", value := "a", leading := "x" }] } "OWS only"
  invalidForm { base with body := "é", fields := base.fields ++ [
    { name := "Content-Length", value := "1" }] } "byte length, not character count"
  invalidForm { base with fields := base.fields ++ [
    { name := "Content-Length", value := "0_0" }] } "ASCII decimal only"
  invalidForm { base with fields := base.fields ++ [
    { name := "Transfer-Encoding", value := "" }] } "no transfer coding"
  invalidForm { base with fields := base.fields ++ [
    { name := "Expect", value := "" }] } "no expectations"
  for (text, error) in [
      ("BAD HTTP/0", Rejection.requestLine),
      ("B@D / HTTP/0", .method),
      ("CUSTOM / HTTP/0", .unsupportedVersion),
      ("CUSTOM / INVALID", .version),
      ("CUSTOM # HTTP/1.1", .unsupportedMethod),
      ("GET # HTTP/1.1", .target),
      ("GET / HTTP/1.1\r\nHost : a", .fieldName),
      ("GET / HTTP/1.1\r\nK: x\r\nHost: a", .fieldName),
      ("GET / HTTP/1.1\r\nHost:", .host),
      ("GET / HTTP/1.1\r\nHost: a\r\nHost:", .duplicateHost),
      ("GET / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: bad", .duplicateLength),
      ("GET / HTTP/1.1\r\nContent-Length: 999999999999999999x", .length),
      ("GET / HTTP/1.1\r\nContent-Length: 999999999999999999", .tooLarge),
      ("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: bad", .transferEncoding),
      ("GET / HTTP/1.1\r\nContent-Length: bad\r\nTransfer-Encoding: chunked", .length),
      ("GET / HTTP/1.1\r\nExpect:", .expect),
      ("GET / HTTP/1.1\r\nX: a", .missingHost)] do
    headerRejection text error
  for status in [Status.ok, .created, .badRequest, .unauthorized, .forbidden, .notFound,
      .methodNotAllowed, .requestTimeout, .payloadTooLarge, .internalServerError, .notImplemented] do
    for contentType in [ContentType.text, .json] do
      for body in ["", "ASCII", "é😀", "\r\nInjected: header\r\n\x00"] do
        let response : Response := { status, contentType, body }
        for headOnly in [false, true] do
          check (decide (ResponseRepresents response headOnly (Wire.render response headOnly)))
            "response byte contract"
  IO.println "HTTP specification tests passed"

end Tests.HttpSpec
