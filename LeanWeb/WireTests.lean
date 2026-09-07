import LeanWeb.Wire

namespace LeanWeb.WireTests

private def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"Wire test failed: {label}")

private def parsed (bytes : ByteArray) (limit : Nat := Wire.defaultMaxRequestBytes) :
    IO Request := do
  match Wire.parse bytes limit with
  | .ok (some request) => return request
  | result => throw (IO.userError s!"Expected complete request, got {repr result}")

private def rejected (bytes : ByteArray) (status : Status := .badRequest)
    (limit : Nat := Wire.defaultMaxRequestBytes) : IO Unit := do
  match Wire.parse bytes limit with
  | .error response => check (response.status == status) s!"status for {repr bytes.data}"
  | result => throw (IO.userError s!"Expected rejection, got {repr result}")

/-- Pure wire regressions; callable from a test entrypoint without opening sockets. -/
def run : IO Unit := do
  let get := "GET /raw%2Fpath?x=a%20b?c HTTP/1.1\r\nHost: localhost\r\n\r\n"
  let request ← parsed get.toUTF8
  check (request.method == .get && request.path == "/raw%2Fpath" &&
    request.query == "x=a%20b?c" && request.body == "") "raw target and query"
  check (request.header? "HOST" == some "localhost") "case-insensitive header lookup"
  let unicode := String.singleton (Char.ofNat 0xe9) ++ String.singleton (Char.ofNat 0x1f600)
  let headerBlock := "POST / HTTP/1.1\r\nhOsT:\tlocalhost \t\r\nContent-Length: 0006\r\n" ++
    "X-Test: a:b\r\nX-Test: c\r\n\r\n"
  let bytes := (headerBlock ++ unicode).toUTF8
  let request ← parsed bytes bytes.size
  check (request.body == unicode && request.header? "host" == some "localhost")
    "UTF-8 body and OWS"
  check (request.headers == [("host", "localhost"), ("content-length", "0006"),
    ("x-test", "a:b"), ("x-test", "c")]) "header order, colons, and ordinary duplicates"
  for i in [:bytes.size] do
    match Wire.parse (bytes.extract 0 i) bytes.size with
    | .ok none => pure ()
    | result => throw (IO.userError s!"Prefix {i} was not incomplete: {repr result}")
  for method in ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] do
    let request ← parsed s!"{method} / HTTP/1.1\r\nHost: localhost\r\n\r\n".toUTF8
    check (some request.method == Method.parse method) s!"method {method}"
  let star ← parsed "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n".toUTF8
  check (star.path == "*") "OPTIONS asterisk"
  let zero ← parsed "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".toUTF8
  check zero.body.isEmpty "zero content length"
  for input in [
      "GET / HTTP/1.1\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nHOST: a\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: \t\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a b\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a,b\r\n\r\n",
      "GET  / HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET / HTTP/1.1 \r\nHost: a\r\n\r\n",
      "GET\t/ HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET / INVALID\r\nHost: a\r\n\r\n",
      "GET /#frag HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET /?x=#frag HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET /\t HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET * HTTP/1.1\r\nHost: a\r\n\r\n",
      "GET / HTTP/1.1\nHost: a\n\n",
      "GET / HTTP/1.1\rHost: a\r\n\r\n",
      "GET / HTTP/1.1\r\nHost : a\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\n folded: x\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nNo-Colon\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\n: value\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nBad(Name: value\r\n\r\n"] do
    rejected input.toUTF8
  for value in ["", "-1", "+1", "1, 1", "1 0", "0x10", "1x", "1\t0"] do
    rejected s!"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: {value}\r\n\r\n".toUTF8
  for second in ["0", "1"] do
    rejected ("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n" ++
      s!"content-length: {second}\r\n\r\n").toUTF8
  for header in ["Transfer-Encoding: chunked", "Transfer-Encoding: identity",
      "Transfer-Encoding:", "Expect: 100-continue", "Expect:"] do
    rejected s!"POST / HTTP/1.1\r\nHost: a\r\n{header}\r\n\r\n".toUTF8 .notImplemented
  for version in ["HTTP/1.0", "HTTP/2.0", "HTTP/3.0"] do
    rejected s!"GET / {version}\r\nHost: a\r\n\r\n".toUTF8 .notImplemented
  for method in ["CONNECT", "TRACE", "get", "CUSTOM"] do
    rejected s!"{method} / HTTP/1.1\r\nHost: a\r\n\r\n".toUTF8 .notImplemented
  rejected (get ++ get).toUTF8
  rejected (get ++ "x").toUTF8
  rejected (bytes ++ "x".toUTF8)
  rejected bytes .payloadTooLarge (bytes.size - 1)
  rejected (bytes.extract 0 headerBlock.toUTF8.size) .payloadTooLarge (bytes.size - 1)
  rejected "GET /".toUTF8 .payloadTooLarge 5
  rejected ByteArray.empty .payloadTooLarge 0
  rejected "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 999999999999999999999\r\n\r\n".toUTF8
    .payloadTooLarge
  -- Invalid, overlong, surrogate, and truncated UTF-8 sequences at an exact body boundary.
  for invalid in [#[255], #[192, 175], #[237, 160, 128], #[195]] do
    let invalid := ByteArray.mk invalid
    rejected (s!"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: {invalid.size}\r\n\r\n".toUTF8 ++ invalid)
  rejected ("GET / HTTP/1.1\r\nHost: a\r\nX: ".toUTF8 ++
    ByteArray.mk #[255] ++ "\r\n\r\n".toUTF8)
  rejected ("GET / HTTP/1.1\r\nHost: a\r\nX: ".toUTF8 ++
    ByteArray.mk #[0] ++ "\r\n\r\n".toUTF8)
  rejected ("GET /".toUTF8 ++ ByteArray.mk #[127] ++ " HTTP/1.1\r\nHost: a\r\n\r\n".toUTF8)
  let rawBody := ByteArray.mk #[13, 10, 0]
  let request ← parsed ("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\n".toUTF8 ++ rawBody)
  check (request.body.toUTF8 == rawBody) "body bytes are not parsed as header lines"
  let response := Response.text unicode
  let expectedHeader := "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 6\r\nConnection: close\r\n\r\n"
  check (Wire.render response == (expectedHeader ++ unicode).toUTF8) "render exact byte length"
  check (Wire.render response true == expectedHeader.toUTF8) "HEAD length without body"
  check (Wire.render (.json "{}" .created) ==
    ("HTTP/1.1 201 Created\r\nContent-Type: application/json; charset=utf-8\r\n" ++
     "Content-Length: 2\r\nConnection: close\r\n\r\n{}").toUTF8) "JSON response"
  IO.println "Wire tests passed"

end LeanWeb.WireTests
