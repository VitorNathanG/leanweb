# Architecture And Evidence

## Boundaries

```text
TCP bytes -> Wire.parse -> Request -> Application middleware -> Router
                                      -> Decoder -> Controller -> Response
Response -> Wire.render -> TCP bytes
```

The decoder/controller segment is opt-in. An `Application` can also contain
arbitrary effectful handlers; its type alone does not make those effects verified.

| Boundary | Executable definitions | Evidence | Remaining boundary |
| --- | --- | --- | --- |
| HTTP model | `LeanWeb/Http.lean` | Typed status/content-type choices; serializer tests | General JSON validity and HTTP conformance |
| Route selection | `LeanWeb/Router.lean` | `Router.unique`, lookup/dispatch theorems, application tests | Raw URL normalization and future template ambiguity |
| Policy selection | `LeanWeb/Middleware.lean` | Guard and composition theorems; IO short-circuit tests | Correctness of a supplied policy or rejection action |
| Input binding | `LeanWeb/Decoding.lean` | `Decoder.sound`, `handle_error`, `handle_ok`; decoder tests | URL specification and unproved source-function semantics |
| Pure controllers | `LeanWeb/Application.lean`, `LeanWeb/Decoding.lean` | `VerifiedHandler.ensures`, bound controller contract | Arbitrary service effects |
| Example integration | `LeanWeb/Example.lean` | Body-limit and division proofs; application/TCP tests | General-purpose application security |
| HTTP wire | `LeanWeb/Wire.lean` | `LeanWeb/WireTests.lean`, `tests/http.test.mjs` | Framing/serializer correctness is tested, not proved |
| TCP lifetime | `LeanWeb/Server.lean` | Real-socket tests and pinned upstream source evidence | Cancellation, deadlines, concurrency, cleanup qualification |

The [API proof table](../README.md#what-is-proved) lists the individual guarantees.
Keep statements about those guarantees tied to their definitions and hypotheses.

## Decision Register

| Decision | Design status | Implementation status | Qualification |
| --- | --- | --- | --- |
| Pure core with an IO boundary | Selected | Router, middleware, decoders, controllers, and application adapter exist | Core theorems plus executable tests; no general IO verifier |
| Explicit services through `ReaderT` | Selected | Example injects a greeting effect | Application tests; no reflection or lifecycle container |
| Exact method/raw-path keys | Selected | Registration carries `Nodup`; HEAD is explicit | Route proofs and TCP regressions; templates remain open |
| Decoder/controller precondition connection | Selected | `Decoder.sound` supplies `Controller.run` with a proof | Source-relation, division, and rejection tests/proofs |
| Narrow HTTP/1.1 profile | Selected for development | One request/connection, bounded input, fixed response headers | Wire/TCP regressions, not RFC qualification |
| Internal Lean TCP binding | Provisional | Sequential adapter on the pinned toolchain | Cancellation blocker documented below; not operationally qualified |
| Concurrent cancellable transport | Open | Not implemented | Must meet the product's operational gate |

## Trusted Basis

Lean's kernel checks proof terms. Proofs may depend on standard Lean axioms; use
`#print axioms` on changed important declarations to inspect that dependency set.
The project does not use custom axioms, proof placeholders, or native evaluation
as a substitute for kernel-checked proofs. This is not an independent verification
of Lean's kernel, elaborator, standard library, compiler, or generated machine code.

The parser and serializer, compiled execution, IO scheduling, FFI, libuv, and OS
remain outside the application's proofs. A decoder relation to `String.toNat?`
or `Decoder.queryValue` is not a proof that those functions implement a complete
external format specification. Runtime evidence and explicit protocol limits
remain necessary.

## Transport Blocker

The current binding cannot safely be given a receive deadline merely by racing a
timer against `recv?` and forgetting the losing operation. Pending reads retain
resources, and cancellation must resolve their ownership correctly. The pinned
runtime has a concrete source-level cancellation concern documented in the
[TCP cancellation assessment](../research/lean-tcp-cancellation/README.md).

`shutdown` is write-side shutdown, not a replacement for cancelling a pending
receive. A proxy or a timeout in the test harness does not establish a server-side
deadline. Toolchain/runtime qualification and bounded connection ownership must
precede operational claims; the [roadmap](../ROADMAP.md) orders that delivery.
