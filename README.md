# LeanWeb

A small Lean 4 web framework with a formally verified core and a real TCP server.
The direction is Spring-like application structure, but with explicit dependencies and
proof-carrying components instead of reflection. This is a working foundation, not a
production framework or a verified HTTP stack.

Project guidance: [Product](PRODUCT.md), [Roadmap](ROADMAP.md),
[Architecture](docs/architecture.md), [Development](docs/development.md), and
[Agent Working Agreement](AGENTS.md). The API and HTTP subset are documented here;
delivery order and development workflow have their own authoritative documents.

## Run

Install [elan](https://github.com/leanprover/elan#installation), Lean's toolchain manager.
The repository pins Lean **4.33.1** in `lean-toolchain`; there are no external Lean dependencies.

```sh
lake build
lake exe leanweb                 # 127.0.0.1:8080
lake exe leanweb 9090            # optional port
```

```sh
curl -i http://127.0.0.1:8080/health
curl -I http://127.0.0.1:8080/health
curl -i http://127.0.0.1:8080/
curl -i --data-binary 'hello Lean' http://127.0.0.1:8080/echo
curl -i --data-binary '17' 'http://127.0.0.1:8080/divide?by=5'
```

The example exposes `GET /` through an injected greeting service, `GET /health`,
`HEAD /health`, `POST /echo`, and `POST /divide?by=<divisor>`. The division endpoint
reads an unsigned decimal dividend from the body and returns
`{"quotient":3,"remainder":2}` for dividend 17 and divisor 5. Its middleware rejects UTF-8 bodies larger
than 64 KiB, measured in bytes. The transport separately caps the entire request at 1 MiB.
Stop the server with Ctrl-C.

## Application Model

| Component | Role |
| --- | --- |
| `Request`, `Response` | Typed HTTP data; finite status and content-type choices |
| `Handler α` | A request-to-result function, independent of an effect system |
| `Router α` | Exact method/path routes with a proof that keys have no duplicates |
| `Middleware α` | Handler transformation, composition, and short-circuit policies |
| `VerifiedHandler post` | Pure controller plus a proof of its response contract |
| `Decoder α valid` | Typed request decoder with a proof that success establishes `valid` |
| `Controller α pre post` | Pure typed controller that requires a proof of its precondition |
| `Action Services` | `ReaderT Services IO Response`, explicit dependency injection |
| `Application Services` | Router, middleware, fallback, and an IO handler adapter |
| `Wire`, `Server` | Small HTTP/1.1 codec and Lean/libuv TCP transport |

A controller can carry an application-specific contract:

```lean
import LeanWeb

open LeanWeb

def echo : VerifiedHandler (fun request response =>
    response.status = .ok ∧ response.body = request.body) where
  run := fun request => .text request.body
  ensures := fun _ => ⟨rfl, rfl⟩

def routes : Router (IO Response) :=
  (Router.empty : Router (IO Response))
    |>.add ⟨.post, "/echo"⟩ echo.lift
```

`Router.add` requires a proof that the new key is absent. For concrete route tables,
the default `by decide` discharges this during compilation. Registering the same
method/path twice fails to compile. Different methods on the same path are allowed.
For computed tables, the caller must supply the freshness proof explicitly.

See [`LeanWeb/Example.lean`](LeanWeb/Example.lean) for the complete application, including
effectful dependency injection and a policy proof over the actual application handler.
Middleware composition is `outer (inner handler)`: requests enter outer first;
responses return through outer last. HEAD routes are explicit, not inferred from GET.

## Typed Decoding

[`LeanWeb/Decoding.lean`](LeanWeb/Decoding.lean) provides a small, composable decoding layer:

- `Decoder.bodyNat` reads a natural number from the entire request body.
- `Decoder.queryNat name` reads a natural number from one exact query key.
- `Decoder.nat source field maxDigits` builds a numeric decoder from an application-defined text source.
- `left.zip right` combines inputs and their validity proofs, returning the first error from left to right.
- `decoder.refine constraint error` checks a decidable constraint and strengthens the decoder's contract.
- `decoder.handle reject next` supplies `next` with the decoded value **and a proof** of its validity, or selects rejection without invoking `next`. Its result may be an IO action.
- `controller.bind decoder` connects matching preconditions and produces a `VerifiedHandler`. That handler proves either the explicit decoding-error response or the controller's postcondition for the decoded input.

For example, a schema can establish positivity before any controller runs:

```lean
def positiveBody : Decoder Nat (fun request n =>
    request.body.toNat? = some n ∧ 0 < n) :=
  Decoder.bodyNat.refine (fun n => 0 < n) (.invalid "positive body")
```

The division example combines a body decoder with `queryNat "by"`, then requires
the dividend to be in `0..1000000` and the divisor in `1..1000000`. Its controller
uses the positivity proof to establish the Euclidean division laws for the
quotient and remainder encoded in its response. Input/source relations are retained
alongside the range constraints; the proof is about the numbers actually decoded.

Decoding errors are structured as `DecodeError.missing`, `.invalid`, or `.duplicate`.
The built-in controller adapter renders them as HTTP 400 text responses, without
echoing submitted values. A custom `Decoder.handle` rejection function can choose
different behavior. Missing divisors, zero divisors, out-of-range numbers, malformed
numerals, and duplicate `by` fields all fail before the division controller runs.

Numeric syntax is deliberately narrow: nonempty ASCII digits only, no signs,
whitespace, fractional/exponent notation, or trimming. Leading zeros are accepted.
The numeric decoders default to at most 20 characters, checked **before** numeric
conversion, and use Lean's arbitrary-precision `Nat`. `Decoder.nat` exposes a
configurable digit limit; the division schema separately enforces its numeric range.
Content-Type is not inspected: these are text decoders, not JSON or form decoders.

Query binding is raw and opt-in: exact, case-sensitive keys; no percent decoding
or `+` conversion. Each field must be `key=value` with a nonempty key and no extra
`=`. Malformed fields anywhere in the query are rejected; well-formed unrelated
fields are ignored. Repeated selected keys are rejected even if values agree.
For example, `by=%35` is invalid and `%62y=5` does not supply the `by` key. This is
not a general URL/form parser. Path parameters and JSON schemas are not implemented.

## What Is Proved

`lake build` checks the following with Lean's kernel. There are no `sorry`, custom
axioms, or `native_decide` proofs in the project. Warnings are treated as build errors.

| Guarantee | Definition or theorem |
| --- | --- |
| A router's method/path keys have no duplicates | `Router.unique`, preserved by `Router.add` |
| A selected handler belongs to a matching registered route | `Router.lookup_sound` |
| Lookup fails exactly when the key is absent | `Router.lookup_none_iff` |
| A missing key invokes the fallback | `Router.dispatch_missing` |
| A fresh route is reachable | `Router.dispatch_added` |
| Adding a different key preserves dispatch | `Router.dispatch_add_other` |
| A denied policy returns rejection, not the downstream action | `Middleware.guard_denied` |
| An allowed policy returns the downstream action | `Middleware.guard_allowed` |
| Middleware composition is associative with an identity | `Middleware.compose_assoc`, `identity_left`, `identity_right` |
| Pure controllers satisfy their declared response contracts | `VerifiedHandler.ensures`, instantiated by health and echo |
| Oversized bodies select rejection in the example, for any services | `Example.oversized_body_rejected` |
| Successful decoding establishes the declared source relation and constraints | `Decoder.sound`, preserved by `zip` and strengthened by `refine` |
| Failed decoding selects rejection; successful decoding supplies a validity proof | `Decoder.handle_error`, `Decoder.handle_ok` |
| Bound controllers return either a decoding-error response or a response satisfying their postcondition | `(Controller.bind controller decoder).ensures` |
| Division output reconstructs the dividend and has a remainder smaller than the divisor | `Example.divisionController.ensures` |

The routing and middleware theorems quantify over their inputs, rather than testing
a handful of example URLs. The guard theorem is equality of the selected result,
including when that result is an IO action. It does not prove that a policy correctly
implements your security requirements or that an arbitrary rejection handler has no effects.

**Proof boundary:** these guarantees concern the Lean request model and pure core.
They do not establish HTTP/RFC conformance, HTTP parser correctness, general JSON validity,
network reliability, runtime/compiler correctness, resource safety, or properties of
arbitrary IO services. Numeric decoder proofs relate successful results to Lean's
`String.toNat?` and the specified source function. The raw query binder's syntax
and duplicate-key behavior are regression-tested, not proved against a URL specification.
`VerifiedHandler.lift` wraps a proved pure result in `pure`; neither it nor
`Decoder.handle` is a general-purpose verifier for effectful controllers. The TCP FFI, libuv,
OS, compiler, and Lean runtime remain outside the application proofs.

## HTTP Subset

- HTTP/1.1 only, one request per connection, always `Connection: close`.
- GET, HEAD, POST, PUT, PATCH, DELETE, and OPTIONS are parsed. Unregistered keys return 404, including wrong methods; there is no automatic 405/Allow handling.
- Origin-form ASCII targets and `OPTIONS *`; the wire parser leaves path and query raw. No percent decoding, path normalization, or path-parameter binding. Numeric query binding is available separately in the application decoding layer.
- Strict CRLF framing and header names; a unique, nonempty Host is required. Host syntax checks are limited, with no virtual-host validation.
- Bodies use a unique decimal Content-Length and valid UTF-8. No Content-Length means an empty body. Binary bodies are not supported.
- Ordinary duplicate headers are preserved; `Request.header?` returns the first value. Security-sensitive middleware must define its own duplicate-header policy.
- Transfer-Encoding, Expect, unsupported methods, and unsupported HTTP versions return 501. Malformed input returns 400; limits return 413.
- Already-buffered trailing/pipelined bytes are rejected. After a complete request, the connection closes; later requests on that connection are not processed.
- Responses compute Content-Length from UTF-8 bytes. HEAD suppresses the body while retaining the length. Application strings cannot become response headers; custom headers are not yet supported.
- Handler exceptions become 500 responses without exposing exception details. Connection IO errors are isolated from the accept loop.

`Server.Config` defaults to **32 active connections** (`maxConnections`) and a
**5,000 ms total request-read deadline** (`requestTimeoutMs`). Both must be positive.
The deadline starts when the server accepts a connection and includes all request
fragments and parsing; incoming bytes do not refresh it. Expiry closes the connection
without an HTTP response or invoking a handler. A request must be selected before
expiry; this is not a deadline on the handler or response write.

At capacity the single accept loop waits for a worker to finish. Excess clients
wait in the OS listen backlog, subject to OS overflow behavior, rather than getting
an HTTP 503. Time in that backlog is **not** covered by the request-read deadline.
Workers retain their slots through handler execution and awaited sends; the runtime
finalizer closes each socket afterward. Handlers and injected services may now run
concurrently and must synchronize shared mutable state themselves.

**Development transport only:** there are still no handler/write deadlines, TLS,
or graceful-stop API. Hanging handlers or stalled writes can exhaust all slots.
The limit covers server-owned connection workers, not arbitrary work or memory
allocated by a handler. Do not expose the server directly to untrusted networks.
The [runtime qualification](research/lean-4.33-receive-deadline/README.md) records
receive cancellation tests, finite-run resource observations, and remaining
listener/runtime error-path limitations. It is not a resource-safety proof or
production qualification. Internal TCP APIs remain part of the toolchain pin.

## Verify

```sh
lake build                       # compile executables and kernel-check proofs
lake exe leanweb_tests           # core, decoders, application, parser, and serializer tests
node --test tests/http.test.mjs   # real TCP tests; Node.js 22+, no npm packages
node scripts/check-workflow.mjs  # documentation links and workflow structure
```

The socket suite starts and stops its own server on an available loopback port.
It checks fragmented UTF-8 requests, response framing, HEAD, exact routing,
dependency injection, malformed input, unsupported features, premature EOF,
size boundaries, typed body/query decoding, division results, and recovery after
rejection. A separate test-only executable exercises concurrent healthy/slow clients,
absolute deadlines, admission backpressure, completion races, disconnects, stalled
writes, handler errors, and Linux self-process descriptor recovery. Decoder tests
also check numeric syntax, leading zeros, digit limits,
range boundaries, composition, source relations, and effect short-circuiting.
CI runs the build, executable tests, and workflow checks. Focused commands and
proof-dependency inspection are documented in [Development](docs/development.md).

## Agent Workflow

OpenCode discovers the project subagents and skills under `.opencode/` without a
repository-specific provider or model configuration. The root agent integrates;
researchers supply bounded evidence, the curator maintains the research catalog,
and the proof reviewer is read-only. See [agent operation](docs/development.md#agent-operation)
for discovery commands, ownership, and restart requirements.

## Future Work

[ROADMAP.md](ROADMAP.md) owns future work in execution order. Acceptance gates and
non-goals belong in [PRODUCT.md](PRODUCT.md); the roadmap is not an implementation
status dashboard.

Reflection, annotations, auto-discovery, ORM integration, transactions, and a DI
container are intentionally out of scope for this first slice.
