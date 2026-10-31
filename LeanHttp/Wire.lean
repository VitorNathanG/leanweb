import LeanHttp.Wire.Scan

namespace LeanHttp.Wire

open Internal

/-- Default aggregate limit, including the request line, headers, delimiter, and body. -/
def defaultMaxRequestBytes : Nat := 1024 * 1024

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
  let some boundary ← headerEnd bytes | do
    if bytes.size == maxRequestBytes then throw tooLarge
    return none
  let endPos := boundary.endPos
  let some header := String.fromUTF8? (extractWithin bytes 0 (endPos - 4)
      (Nat.zero_le _) (by have := boundary.upper; omega))
    | throw (bad "Invalid UTF-8 in headers")
  let { method, target, headers, length } ← parseHead header (maxRequestBytes - endPos)
  let total := endPos + length
  if total > maxRequestBytes then throw tooLarge
  if short : bytes.size < total then return none
  else
    if bytes.size > total then throw (bad "Trailing bytes after request")
    let some body := String.fromUTF8? (extractWithin bytes endPos total (by omega) (by omega))
      | throw (bad "Invalid UTF-8 in body")
    let path :: queryParts := splitChar '?' target | throw (bad "Missing target")
    return some {
      method, path, query := String.intercalate "?" queryParts
      headers, body }

/-- Render an exact UTF-8 byte Content-Length, retaining that length but omitting the HEAD body. -/
def render (response : Response) (headOnly : Bool := false) : ByteArray :=
  let body := response.body.toUTF8
  let header := s!"HTTP/1.1 {response.status.code} {response.status.reason}\r\n" ++
    s!"Content-Type: {response.contentType.value}\r\n" ++
    s!"Content-Length: {body.size}\r\nConnection: close\r\n\r\n"
  if headOnly then header.toUTF8 else header.toUTF8 ++ body

end LeanHttp.Wire
