# Pending TCP Receive Cancellation

Historical assessment of Lean 4.24. The current toolchain's replacement evidence
is the [4.33.1 qualification](../lean-4.33-receive-deadline/README.md); the source
findings below remain scoped to the old pin.

## Question

Can the pinned Lean runtime's internal `Socket.cancelRecv` safely implement a
receive deadline in the current server? This is a source-only assessment of that
specific path, not transport qualification or a reproducible crash report.

## References

Lean v4.24.0 resolves to commit `797c613eb9b6d4ec95db23e3e00af9ac6657f24b`.
Public pinned sources:

- [TCP Lean declarations](https://github.com/leanprover/lean4/blob/797c613eb9b6d4ec95db23e3e00af9ac6657f24b/src/Std/Internal/UV/TCP.lean)
- [TCP runtime implementation](https://github.com/leanprover/lean4/blob/797c613eb9b6d4ec95db23e3e00af9ac6657f24b/src/runtime/uv/tcp.cpp)
- [Promise contract](https://github.com/leanprover/lean4/blob/797c613eb9b6d4ec95db23e3e00af9ac6657f24b/src/Init/System/Promise.lean)
- [Release reference](https://api.github.com/repos/leanprover/lean4/git/ref/tags/v4.24.0)

The application uses [Server.lean](../../LeanWeb/Server.lean). No machine-specific
environment is needed for this source comparison. Platform-dependent runtime
behavior has not been qualified by this report.

## Procedure

Resolve the release tag and inspect the pinned declarations, then compare these
functions in `tcp.cpp`: `lean_uv_tcp_recv`, its completion callback,
`lean_uv_tcp_cancel_recv`, and `lean_uv_tcp_socket_finalizer`. Trace the distinction
between the Lean external-object wrapper and the raw C++ payload returned by
`lean_to_uv_tcp_socket`. Inspect promise dropping and write-side shutdown separately.

No executable probe was run for this assessment. Source statements below are
reproducible by inspecting the named functions at the pinned commit.

## Evidence

### Source Contracts

`recv?` returns a promise containing data, EOF, or an IO error. Parallel receive
operations on one socket are unsupported. The Lean cancellation declaration calls
the operation dangerous and says it resolves a pending receive's returned promise
to `none`. `IO.Promise.result?` separately returns `none` if a promise is dropped
without resolution; that outer cancellation result differs from a receive's EOF.

### Implementation Observations

`lean_uv_tcp_recv` retains the Lean `socket` wrapper using `lean_inc(socket)`.
Its normal completion callback releases `(lean_object*)stream->data`, the wrapper
stored on the libuv handle.

The pending cancellation path instead obtains the C++ payload through
`lean_to_uv_tcp_socket(socket)`, stops reading, clears/decrements pending objects,
and calls `lean_dec((lean_object*)tcp_socket)`. That casts the payload rather than
releasing the wrapper whose reference count was incremented. The no-pending-read
case returns early and does not exercise this path.

### Executed Tests And Kernel Proofs

None for this assessment. Existing application TCP tests do not call `cancelRecv`
and do not establish cancellation safety. No retained crash probe is being
claimed as evidence here.

### Inference

The payload/wrapper mismatch makes this pinned pending-read cancellation path
unsuitable as the basis of a safe receive deadline. Merely passing an idle-socket
cancellation test would not cover it. Dropping a waiting task is not evidence of
cancelling the libuv operation, and write-side `shutdown` is not a read cancellation.

## Conclusion

Do not add deadlines by invoking this pending-read cancellation path unchanged.
The current adapter deliberately omits cancellation and remains development-only.
A qualified runtime revision or a different transport/ownership mechanism is
needed before making cancellation and deadline guarantees.

## Uncertainty

This report does not establish crash frequency, exact memory effects, scheduler
behavior, promise-resolution timing, or the safety of another Lean version.
A future toolchain selection must inspect the revised path and execute bounded
pending-read, completion-race, repeated-cancel, and cleanup probes. The finding
does not establish that every other TCP lifecycle path is safe.

## Follow-ups

Use the source mismatch to design a focused regression that actually has a
pending read. Qualify promise outcomes and lifetime release as well as process
survival, then exercise the selected fix through the real server's deadline path.
Execution order remains in [ROADMAP.md](../../ROADMAP.md).

## Artifacts

This report only; no probe, binaries, generated outputs, or retained runtime.
The [index entry](../index/README.md) owns status and assignment metadata.
