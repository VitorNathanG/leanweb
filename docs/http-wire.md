# HTTP Wire Profile

This document defines LeanHttp's current development wire contract independently
of `Wire.parse` and `Wire.render`. It is not an HTTP conformance claim.

The declarative [Lean model](../LeanHttp/Spec.lean) specifies successful requests,
incremental outcomes, rejection precedence, and response encoding. It imports
HTTP types, not the parser or server. It uses Lean's UTF-8 string encoder.
Successful parser acceptance is proved equivalent to the request model;
agreement with RFC 3629 remains unproved.

The references are RFC 9112 for HTTP/1.1 messaging, RFC 9110 for HTTP semantics,
and RFC 3629 for UTF-8. Local restrictions and known deviations are explicit below.

## Request Grammar

The grammar uses octets, ABNF repetition and alternatives
([RFC 5234](https://www.rfc-editor.org/rfc/rfc5234.html)), and case-sensitive
`%s` strings ([RFC 7405](https://www.rfc-editor.org/rfc/rfc7405.html)).
Acceptance requires both this grammar and the conditions below.

```abnf
request       = request-line *field-line CRLF body
request-line  = method SP target SP %s"HTTP/1.1" CRLF
method        = %s"GET" / %s"HEAD" / %s"POST" / %s"PUT"
              / %s"PATCH" / %s"DELETE" / %s"OPTIONS"
target        = "/" *target-octet / "*"
target-octet  = %x21-22 / %x24-7E
field-line    = field-name ":" *field-octet CRLF
field-name    = 1*token-octet
token-octet   = ALPHA / DIGIT / %x21 / %x23-27 / %x2A-2B
              / %x2D-2E / %x5E-60 / %x7C / %x7E
field-octet   = HTAB / SP / %x21-7E / %x80-FF
body          = *OCTET
ALPHA         = %x41-5A / %x61-7A
DIGIT         = %x30-39
SP            = %x20
HTAB          = %x09
CRLF          = %x0D.0A
OCTET         = %x00-FF
```

There are exactly two separating spaces in the request line, no leading blank
line, no whitespace before a field's colon, and no folded field lines.
The target `*` is accepted only with OPTIONS. Targets contain no spaces,
controls, non-ASCII octets, or `#`.

The target rule is deliberately a lexical description, not RFC URI validation:
it also permits malformed percent escapes and characters forbidden in an RFC
URI. See [Known RFC Deviations](#known-rfc-deviations).

## Field Conditions And Decoded Values

Field names are ASCII case-insensitive. Strip only leading and trailing SP and
HTAB from each field value before applying these conditions:

- Exactly one Host field is required. Its value must be nonempty ASCII
  `%x21-7E`, excluding comma, slash, backslash, `@`, `#`, and `?`.
  This is not full hostname, IP-literal, or port validation. The value is not
  resolved or compared with the listening address.
- At most one Content-Length field is allowed. Its value must contain one or
  more ASCII decimal digits. Leading zeros are allowed; signs, internal
  whitespace, separators, and comma-separated lengths are rejected.
- Transfer-Encoding and Expect fields are unsupported, including empty values.
  Content-Length never makes a Transfer-Encoding request acceptable.
- Other fields may repeat. Preserve their order and separate values; do not
  combine comma lists or validate field-specific semantics.

Both the complete header block and the body must be valid UTF-8 as defined by
[RFC 3629 §4](https://www.rfc-editor.org/rfc/rfc3629.html#section-4).
Reject overlong encodings, surrogates, values above U+10FFFF, and incomplete
sequences at the end of either region. Only the body permits ASCII control
octets such as NUL, CR, and LF; header values permit HTAB but no other controls
or DEL. Do not strip a body BOM, replace invalid bytes, or normalize Unicode.

Decoded requests retain the following source relations:

- `method` is the corresponding case-sensitive method alternative.
- `path` is the target before its first `?`; `query` is everything after it.
  With no `?`, the query is empty. An absent query and a present empty query
  both become `""`. Later question marks remain in the query.
- Paths and queries are not percent-decoded, normalized, or converted from `+`.
- `headers` contains lowercased names and outer-whitespace-trimmed values in
  wire order, including Host and Content-Length. Header lookup returns the
  first matching value; consumers must choose a duplicate policy.
- `body` is the UTF-8 decoding of exactly the framed body octets. Content-Type
  and Content-Encoding do not select a decoder or trigger decompression.

## Framing And Limits

Let `H` be the byte count through the header-ending CRLF CRLF, and `M` the
configured aggregate request-byte limit. Let `N` be the decimal Content-Length
value, or zero when the field is absent.

A complete accepted input has exactly `H + N` octets and satisfies
`H + N <= M`. The limit includes the request line, all fields, delimiters,
and body. Exact-limit requests are allowed; zero permits no complete request.
The server requires a positive limit. The default is 1,048,576 bytes.

Missing Content-Length and Content-Length zero both imply no body, but remain
distinguishable in `headers`. Request bodies are never delimited by EOF.
Their framing does not depend on the method.

There is no separate field-count, line-length, or decimal-digit limit within
the aggregate limit. Arithmetic is over natural numbers without wraparound.
These input constraints do not establish time or memory bounds.

Extra octets already present after the body cause rejection, including another
request or an extra CRLF. The server processes at most one request per
connection; it does not wait for hypothetical future trailing data after
recognizing a complete request.

## Lean Specification

`LeanHttp.Spec.RequestForm` records the method, target, ordered fields, and body.
Origin targets distinguish absent and empty queries. Field forms retain their
original name and separate leading/trailing SP or HTAB from the decoded value.

`RequestForm.Valid` requires the request grammar, normalized field values,
exactly one valid Host, at most one decimal Content-Length, no Transfer-Encoding
or Expect, agreement between declared and encoded body lengths, and the
aggregate byte limit.

`LeanHttp.Spec.Represents limit bytes request` holds when a valid form encodes
exactly `bytes` and decodes to `request`.

`LeanHttp.Spec.RequestOutcome` relates input bytes to a complete request, more
input needed, or a rejection. Raw-byte and decoded-header conditions determine
the validation order. A rejection requires the earlier checks to pass; waiting
does not require that the input can be extended to a valid request.

`LeanHttp.Spec.ResponseRepresents` specifies the exact response bytes, including
the encoded body length and HEAD body omission. It uses the finite HTTP values
from `LeanHttp.Types`, not `Wire.render`.

These definitions do not execute the production parser or server. UTF-8 is
specified through string-encoding witnesses, leaving agreement between Lean's
encoder and RFC 3629 as a separate obligation.

`LeanHttp.Wire.parse_iff_represents` in `LeanHttp/Wire/Correctness.lean` proves,
for every byte buffer, limit, and request:

```lean
Wire.parse bytes limit = .ok (some request) ↔
  Spec.Represents limit bytes request
```

This establishes successful acceptance and decoded source fields in both
directions.

`LeanHttp/Wire/Incremental.lean` additionally proves:

| Theorem | Guarantee for a request accepted at the same limit |
| --- | --- |
| `parse_body_boundary` | Exactly the decoded body's UTF-8 bytes follow the scanned header boundary. |
| `parse_contentLength` | Missing Content-Length means an empty body; otherwise exactly one decimal length equals the body's byte count. |
| `parse_no_unsupported_fields` | Accepted headers contain neither Transfer-Encoding nor Expect. |
| `parse_prefix` | Every proper byte prefix returns `ok none`. |
| `parse_chunks` | Every finite chunk partition, including empty chunks, waits until all request bytes are present and returns the same request. |
| `parse_append` | Any nonempty buffered suffix is rejected: aggregate overflow takes precedence over trailing bytes. |

`LeanHttp/Wire/Bounds.lean` proves that every `ok` result stays within the aggregate
byte limit, `ok none` leaves a positive byte budget, and every oversized buffer
returns 413 before syntax checks. A successfully decoded body's UTF-8 bytes fit
the budget remaining after its header boundary. Empty input waits at a positive
limit; a zero limit returns 413.

The executable scanner's indexed reads and parser's header/body slices carry
Lean bounds proofs. These cover incomplete and rejected input too, but do not
prove time or memory bounds or the correctness of compiled code, byte-array
primitives, or UTF-8 routines.

These are pure byte-buffer guarantees. They exclude EOF, deadlines, socket
behavior, and data arriving after completion. General rejection/incomplete-input
equivalence and outcome determinism remain unproved.

## Incomplete Input And Rejection

The parser interface distinguishes a complete request, more input needed, and
rejection. “More input needed” does not certify that the prefix is valid: some
syntax checks wait for the complete header block.

Before the header terminator, reject forbidden control octets, bare LF, and CR
followed by a non-LF octet. A final CR can await another octet. Without a header
terminator, reaching the byte limit causes 413; exceeding the limit does too.
After valid headers, a declared body larger than the remaining budget causes
413 immediately; otherwise an incomplete body awaits more input.

For isolated failures, the current classifications are:

| Condition | Result |
| --- | --- |
| Malformed request/field syntax, invalid UTF-8, invalid or duplicate Host/Content-Length, or buffered trailing data | 400 |
| Unsupported method token, version beginning with `HTTP/`, Transfer-Encoding, or Expect | 501 |
| Aggregate input or declared body exceeds its budget, or headers exhaust the limit without a terminator | 413 |
| EOF while awaiting more input, before the server deadline | 400 |
| Server request-read deadline expires | Close without a response or handler |

Malformed method tokens and version strings not beginning with `HTTP/` are
400 errors. Rejections do not select an application handler.

When failures coexist, aggregate overflow is checked first, then header
framing and UTF-8, request-line shape, method-token syntax, version, supported
method, target, and fields in wire order. Missing Host is checked after the
fields; body completeness and UTF-8 follow. A framing error precedes the
no-terminator limit check. For Content-Length, digit syntax precedes its
numeric budget check. Do not assume one status for every invalid combination.

The server's deadline applies before response selection, including rejection
responses. IO failures can prevent delivery; this profile does not promise a
response after every rejection.

## Responses

Responses use HTTP/1.1 and the finite status/reason and content-type choices in
[`LeanHttp/Types.lean`](../LeanHttp/Types.lean). Their wire layout is:

```text
HTTP/1.1 <status> <reason>\r\n
Content-Type: <content-type>\r\n
Content-Length: <decimal UTF-8 body byte count>\r\n
Connection: close\r\n
\r\n
<body bytes>
```

The decimal count has no leading zeros except for zero itself. HEAD responses
omit body bytes but retain the supplied response body's encoded length.
Ensuring that a HEAD handler describes the corresponding GET representation
is the application's responsibility; the transport does not derive it.

Application body text cannot add header fields. No custom response headers,
chunked encoding, interim responses, upgrades, or connection reuse are provided.

`LeanHttp/Wire/Response.lean` proves the following for every response and HEAD flag:

| Theorem | Guarantee |
| --- | --- |
| `render_represents` | Rendered bytes match `Spec.ResponseRepresents`. |
| `render_contentLength` | The emitted Content-Length field decodes to the body's UTF-8 byte count, including for HEAD. |
| `render_boundary`, `render_header`, `render_body_bytes` | The first header terminator ends the header block; the suffix is exactly the body, or empty for HEAD. |
| `render_same_headers` | Changing body contents preserves headers when status, content type, and UTF-8 byte count stay unchanged. |

These proofs do not establish full HTTP semantics, encoder conformance, compiled
execution, or transport correctness.

## RFC Relationship

| Area | Reference and local behavior |
| --- | --- |
| Octet framing and request line | [RFC 9112 §§2–3](https://www.rfc-editor.org/rfc/rfc9112.html#section-2). Strict CRLF and single-space separators; no optional whitespace recovery. |
| Fields and folding | [RFC 9112 §5](https://www.rfc-editor.org/rfc/rfc9112.html#section-5) and [RFC 9110 §5.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.5). Reject folding and restrict field values to valid UTF-8 instead of accepting arbitrary opaque high octets. |
| Length framing | [RFC 9112 §§6.2–6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.2) and [RFC 9110 §8.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6). Decimal byte lengths; absent length means zero. Reject even identical duplicate lengths rather than repairing them. |
| HEAD | [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3). No response body; representation-length correctness also depends on the handler. |
| Closing | [RFC 9112 §9.6](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.6). One request, then close; no persistent-connection support. |

### Known RFC Deviations

- Target and Host checks are incomplete. For example, `/%zz` and `Host: [`
  pass their lexical checks but are not valid under the URI/Host grammars in
  [RFC 9112 §3.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2),
  [RFC 9110 §7.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-7.2), and
  [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html).
- Absolute-form targets and chunked requests are rejected, although
  [RFC 9112 §3.2.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2.2)
  and [§6.1](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.1) require
  recipients to support them.
- Blanket 501 responses are not RFC-specific error classification. In
  particular, requests whose final transfer coding is not chunked require
  400 under [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3).
  Expect and version handling also omit the distinctions described in
  [RFC 9110 §10.1.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.1.1)
  and [§15.6.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.6.6).

This list is not a complete conformance audit. Proving this local profile would
not prove full RFC conformance, proxy agreement, or immunity to request
smuggling. Transport ownership, deadlines, and operational limits remain in
the [architecture](architecture.md) and [HTTP overview](../README.md#http-subset).
