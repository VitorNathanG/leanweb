# Roadmap

Future work only, in execution order. Acceptance gates belong in
[PRODUCT.md](PRODUCT.md); current decisions belong in
[Architecture](docs/architecture.md). Supporting research should enable the next
working behavior, not postpone it indefinitely.

- Complete handler, write, and shutdown deadline semantics and graceful stop.
  Qualify a transport abort/close path and listener-error cleanup before promising
  reclamation; the current runtime still has relevant lifecycle limitations.
  State what can actually be cancelled, prevent abandoned work from publishing
  effects where promised, and test slow readers, throwing/hanging handlers,
  in-flight shutdown, and repeated start/stop with owned-process diagnostics.
- Add structured connection and request diagnostics without exposing secrets or
  request bodies by default. Exercise sanitized 500 responses, listener failures,
  connection-error recovery, and bounded diagnostic output through the server.
- Add typed path parameters through a runnable endpoint. Specify matching and
  ambiguity rules, percent-decoding policy, source relations, and error behavior;
  preserve or replace exact-route uniqueness with an explicit proved contract and
  cover conflicting registrations and rejected targets in kernel and TCP tests.
- Add bounded JSON body schemas and media-type handling. Define duplicate and
  unknown-field policy, numeric/text limits, and error responses; prove successful
  decoding establishes domain preconditions and test malformed and valid bodies
  through a real controller. Do not present a JSON library call as a conformance proof.
- Deliver one stateful service with an explicit invariant and pure transition
  model. Prove preservation and authorization conditions, connect that model to
  the injected service, and test concurrency/failure behavior without extending
  the theorem's claim to unverified IO storage.
- Qualify deployment transport security and operational behavior: TLS termination
  requirements, proxy assumptions, sustained resource pressure, overload, and
  cancellation/fault tests. Define a supported deployment profile before changing
  the product's development-only status.
- Establish reproducible workload benchmarks with stated functionality, proof
  boundary, concurrency, payloads, and host/toolchain identities. Measure latency,
  throughput, and resource use; optimize measured bottlenecks and rerun correctness
  checks rather than using performance work to weaken contracts.
