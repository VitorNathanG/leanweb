import LeanWeb.Http

namespace LeanWeb.Wire

/-- Default aggregate limit, including the request line, headers, delimiter, and body. -/
def defaultMaxRequestBytes : Nat := 1024 * 1024

private def bad (message : String) : Response :=
  .text (message ++ "\n") .badRequest

private def tooLarge : Response := .text "Request too large\n" .payloadTooLarge

private def unsupported (message : String) : Response :=
  .text (message ++ "\n") .notImplemented

private def asciiAlphaNum (c : Char) : Bool :=
  ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9')

private def tokenChar (c : Char) : Bool :=
  asciiAlphaNum c || "!#$%&'*+-.^_`|~".contains c

private def trimOWS (s : String) : String :=
  let space := fun c => c == ' ' || c == '\t'
  String.ofList ((s.toList.dropWhile space).reverse.dropWhile space).reverse

/-- Scan only the header block; a CR at the end of an incomplete buffer is allowed. -/
private def headerEnd (bytes : ByteArray) : Except Response (Option Nat) := do
  for i in [:bytes.size] do
    let b := bytes[i]!
    if b == 10 && (i == 0 || bytes[i - 1]! != 13) then
      throw (bad "Bare LF in headers")
    if b == 13 && i + 1 < bytes.size && bytes[i + 1]! != 10 then
      throw (bad "Bare CR in headers")
    if (b < 32 && b != 9 && b != 10 && b != 13) || b == 127 then
      throw (bad "Control character in headers")
    if b == 13 && i + 3 < bytes.size && bytes[i + 1]! == 10 &&
        bytes[i + 2]! == 13 && bytes[i + 3]! == 10 then
      return some (i + 4)
  return none

private def contentLength (value : String) (limit : Nat) : Except Response Nat := do
  if value.isEmpty || !value.toList.all (fun c => '0' <= c && c <= '9') then
    throw (bad "Invalid Content-Length")
  let mut n := 0
  for c in value.toList do
    n := n * 10 + (c.toNat - '0'.toNat)
    if n > limit then throw tooLarge
  return n

/--
Parse one HTTP/1.1 request incrementally. `ok none` means more bytes are needed;
`error` is a response suitable for closing the connection. The limit includes all wire bytes.

This is a deliberately small adapter, not a complete HTTP implementation: ASCII origin-form targets
(and `OPTIONS *`), UTF-8 headers/bodies, Content-Length only, no upgrades or keep-alive.
Paths and queries remain raw, with no percent decoding. Header names are lowercased and only
outer SP/HTAB is stripped from values. Host is required, nonempty, and checked for forbidden
authority characters, but is not resolved or compared with the listening address.
An absent Content-Length means an empty body; EOF is never used to delimit a request body.

Bytes beyond the declared body are rejected, including pipelined requests already in this buffer.
A caller must close after success, not use this parser to silently consume a stream prefix.
-/
def parse (bytes : ByteArray) (maxRequestBytes : Nat := defaultMaxRequestBytes) :
    Except Response (Option Request) := do
  if bytes.size > maxRequestBytes then throw tooLarge
  let some endPos ← headerEnd bytes | do
    if bytes.size == maxRequestBytes then throw tooLarge
    return none
  let some header := String.fromUTF8? (bytes.extract 0 (endPos - 4))
    | throw (bad "Invalid UTF-8 in headers")
  let requestLine :: headerLines := header.splitOn "\r\n"
    | throw (bad "Missing request line")
  let [methodText, target, version] := requestLine.splitOn " "
    | throw (bad "Malformed request line")
  if methodText.isEmpty || !methodText.toList.all tokenChar then
    throw (bad "Malformed method")
  if version != "HTTP/1.1" then
    if version.startsWith "HTTP/" then throw (unsupported "Only HTTP/1.1 is supported")
    throw (bad "Malformed HTTP version")
  let some method := Method.parse methodText
    | throw (unsupported "Unsupported method")
  if !(target.startsWith "/" || (target == "*" && method == .options)) ||
      target.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#') then
    throw (bad "Invalid request target")
  let mut headers : List (String × String) := []
  let mut hostSeen := false
  let mut length : Option Nat := none
  for line in headerLines do
    let name :: parts := line.splitOn ":" | throw (bad "Malformed header")
    if parts.isEmpty || name.isEmpty || !name.toList.all tokenChar then
      throw (bad "Malformed header name")
    let name := name.toLower
    let value := trimOWS (String.intercalate ":" parts)
    if value.toList.any (fun c => (c.toNat < 32 && c != '\t') || c.toNat == 127) then
      throw (bad "Invalid header value")
    if name == "host" then
      if hostSeen then throw (bad "Duplicate Host")
      if value.isEmpty || value.toList.any (fun c =>
          c.toNat <= 32 || c.toNat >= 127 || ",/\\@#?".contains c) then
        throw (bad "Invalid Host")
      hostSeen := true
    if name == "content-length" then
      if length.isSome then throw (bad "Duplicate Content-Length")
      length := some (← contentLength value (maxRequestBytes - endPos))
    if name == "transfer-encoding" then
      throw (unsupported "Transfer-Encoding is not supported")
    if name == "expect" then
      throw (unsupported "Expect is not supported")
    headers := (name, value) :: headers
  if !hostSeen then throw (bad "Missing Host")
  let total := endPos + length.getD 0
  if total > maxRequestBytes then throw tooLarge
  if bytes.size < total then return none
  if bytes.size > total then throw (bad "Trailing bytes after request")
  let some body := String.fromUTF8? (bytes.extract endPos total)
    | throw (bad "Invalid UTF-8 in body")
  let path :: queryParts := target.splitOn "?" | throw (bad "Missing target")
  return some {
    method, path, query := String.intercalate "?" queryParts
    headers := headers.reverse, body }

/-- Render an exact UTF-8 byte Content-Length, retaining that length but omitting the HEAD body. -/
def render (response : Response) (headOnly : Bool := false) : ByteArray :=
  let body := response.body.toUTF8
  let header := s!"HTTP/1.1 {response.status.code} {response.status.reason}\r\n" ++
    s!"Content-Type: {response.contentType.value}\r\n" ++
    s!"Content-Length: {body.size}\r\nConnection: close\r\n\r\n"
  if headOnly then header.toUTF8 else header.toUTF8 ++ body

end LeanWeb.Wire
