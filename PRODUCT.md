# LeanWeb Product Contract

## Goal

Build a web application framework in Lean with Spring-like application structure
and selectively verified behavior. Developers should assemble typed controllers,
explicit services, routing, and middleware while proving domain properties where
they provide value. A runnable network application, not only an abstract model,
is the deliverable. Full Spring API compatibility is not a goal.

## Current Scope

The working foundation provides typed HTTP messages, duplicate-free exact route
registration, middleware, explicit `ReaderT` dependency injection, pure controller
contracts, composable typed decoders, and an executable HTTP/1.1 TCP adapter.
The example includes injected greeting, health, echo, and validated division paths.

Source relations and domain constraints are proved for successful decoding. The
division controller proves quotient/remainder laws for the values decoded from
the request. Routing and middleware proofs concern the core definitions that the
application uses; they do not verify the network stack or arbitrary IO services.

The [README](README.md) owns the detailed API and supported HTTP subset.
[Architecture](docs/architecture.md) owns decisions and the evidence/trust map.
[Development](docs/development.md) owns verification procedures.

## Current Acceptance Gate

The current foundation must continue to satisfy all of these:

- Concrete duplicate method/path registration fails during elaboration. Dispatch
  selects only matching routes and uses the fallback for absent keys.
- Policies and decoders select rejection without invoking downstream controller
  actions on denied or invalid input; executable tests cover effect short-circuiting.
- Successful typed decoding retains its relationship to source request fields and
  establishes the controller's precondition. Bound pure controllers carry a proof
  of either the decoding-error response or their declared response postcondition.
- The example is exercised through real loopback TCP, including malformed input,
  fragmented UTF-8, HEAD framing, size limits, and recovery after rejection.
- Proofs and all test targets build under the pinned toolchain with warnings as
  errors. No proof placeholders or custom assumptions are used to pass a check.

## Operational Server Gate

Not met. The current sequential server is development-only: it has no deadlines,
concurrency control, graceful-stop API, or TLS. One slow peer can block later work.
Do not advertise it as production-ready or expose it directly to untrusted networks.

Before changing that status, deliver a working, bounded server path with documented
ownership and cleanup. Qualify concurrent healthy requests alongside slow peers,
overload rejection/backpressure, read/write/handler/shutdown deadline behavior,
disconnects, handler errors, cancellation races, and graceful stop. Resource and
failure tests must exercise the actual transport, not just an isolated API probe.
An upstream runtime change or alternate transport needs explicit evidence and
must preserve the application proof boundary. TLS and deployment hardening are
separate requirements, not consequences of adding concurrency.

## Application Growth Gate

Path parameters and JSON schemas are future capabilities, not implemented ones.
Each added binding must define accepted syntax, ambiguity and duplicate handling,
size limits, media-type behavior, errors, and the relation between source data and
typed values. Connect it to a runnable endpoint, carry the resulting preconditions
into the controller, and test successful and rejected requests over TCP.

For stateful services, name the state invariant and transition semantics before
claiming verification. Prove the pure transition contract and separately exercise
the IO adapter, concurrency, authorization, and failure behavior relevant to it.
A mathematical state model alone does not verify a database or network service.

## Constraints And Non-Goals

- `lean-toolchain` and `lake-manifest.json` own toolchain/dependency identities.
  Linux is the tested development platform; additional platforms require evidence.
- Keep pure contracts separate from IO and external-runtime assumptions. Toolchain
  upgrades must rerun both proof checking and runtime qualification.
- Prefer explicit typed dependencies over reflection, implicit global registries,
  or an unbounded dependency-injection container.
- Never replace unsupported behavior with silent fallback or fake success.
- Do not add ORM integration, transactions, annotation discovery, template engines,
  or compatibility layers without a concrete application requirement.
- Do not claim RFC completeness, general JSON validity, arbitrary IO correctness,
  hard resource bounds, or performance improvements without corresponding evidence.

Future delivery order belongs only in [ROADMAP.md](ROADMAP.md).
