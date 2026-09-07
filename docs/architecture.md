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
| TCP lifetime | `LeanWeb/Server.lean` | Receive/timer probes; concurrent TCP, deadline, backpressure, reset, and FD regressions | Handler/write termination, graceful stop, listener failures, general memory/resource safety |

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
| Internal Lean TCP binding | Provisional | Adapter on the pinned toolchain; no write-side shutdown call | Tested receive cancellation; remaining error-path limitations below |
| Bounded concurrent transport | Partial | Tracked dedicated workers, accept backpressure, absolute read deadline | Actual-server regressions; operational gate remains unmet |

## Trusted Basis

Lean's kernel checks proof terms. Proofs may depend on standard Lean axioms; use
`#print axioms` on changed important declarations to inspect that dependency set.
The project does not use custom axioms, proof placeholders, or native evaluation
as a substitute for kernel-checked proofs. This is not an independent verification
of Lean's kernel, elaborator, standard library, compiler, or generated machine code.

The 4.33.1 upgrade audit added standard `Classical.choice` transitively to
`Decoder.nat`, `Example.divisionController`, and `Example.oversized_body_rejected`.
Upstream `String.toNat?`, `String.length`, and `String.toList` now depend on
`propext`, `Classical.choice`, and `Quot.sound`; comparison with 4.24 isolated that
change. Selected route, middleware, refinement, rejection, and binding audits
added no axioms. No custom assumptions or proof shortcuts were introduced, and
the decoder's source relation and controller preconditions were preserved.
The numeric decoder explicitly enforces ASCII digits because the new upstream
conversion also accepts separators, which LeanWeb's existing syntax forbids.

The parser and serializer, compiled execution, IO scheduling, FFI, libuv, and OS
remain outside the application's proofs. A decoder relation to `String.toNat?`
or `Decoder.queryValue` is not a proof that those functions implement a complete
external format specification. Runtime evidence and explicit protocol limits
remain necessary.

## Transport Ownership

The accept loop holds at most `maxConnections` worker tasks, never overlapping
accepts. Each dedicated worker owns one socket, one pending receive, and one
one-shot timer during input. Its absolute deadline is recorded at acceptance;
the worker checks monotonic time before parsing and before choosing a handler or
rejection response. Receive/timer selection does not itself cancel the loser.
Explicit finalizers cancel receives and timers, and observe the receive's terminal
result, which may be cancellation or raced completion. Only result tasks escape
the promise-producing helper, not unresolved producer promises.

Admission slots are retained until workers finish, including handlers and awaited
sends. There is no detached timeout worker or early slot release. Socket references
then drop for asynchronous UV finalizer close; this is not a hard bound on cleanup
latency. The server no longer calls write-side `shutdown`, whose immediate-error
path leaks references in the pinned runtime. Handler-created tasks/resources are
not controlled by this worker registry. Injected services must tolerate concurrency.

The [4.33.1 qualification](../research/lean-4.33-receive-deadline/README.md) replaces
the old [4.24 cancellation blocker](../research/lean-tcp-cancellation/README.md) for
this slice and owns detailed source and executed evidence. Pending-accept callback
errors still have upstream reference-cleanup defects; listener failure drains known
workers but listener-error reclamation is not qualified. There is no transport
abort for stalled writes and no general cancellation of arbitrary IO handlers.
The [roadmap](../ROADMAP.md) orders the remaining operational requirements.
