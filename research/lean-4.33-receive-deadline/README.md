# Lean 4.33.1 Receive-Deadline Qualification

## Question

Does the pinned compiled runtime support an owned connected socket's pending
receive cancellation and a one-shot timer/receive selection with observable
loser cleanup, including near-completion races?

The researcher qualified the receive-deadline building blocks; root subsequently
added separately labelled actual-server integration evidence below. Write/handler/
shutdown deadlines and graceful server stop remain excluded. Assignment and owner
are recorded in the [research index](../index/README.md).

## References

Candidate: Lean v4.33.1, commit
`819816b2e0a3bf405af45ae5c7af2491d8f5bee6`. The installed executable's
`--version` matched this full commit and reported a Release build.

Public pinned sources (Lean upstream, Apache 2.0):

- [Release tag](https://api.github.com/repos/leanprover/lean4/git/ref/tags/v4.33.1)
- [TCP declarations](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/Std/Internal/UV/TCP.lean)
- [TCP runtime](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/uv/tcp.cpp)
- [Timer declarations](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/Std/Internal/UV/Timer.lean)
- [Timer runtime](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/uv/timer.cpp)
- [Promise contract](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/Init/System/Promise.lean)
- [IO task selection](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/Init/System/IO.lean)

Comparison baseline: Lean v4.24.0,
`797c613eb9b6d4ec95db23e3e00af9ac6657f24b`; see the existing
[source assessment](../lean-tcp-cancellation/README.md). That report was read
before probing. No overlapping experimental assignment existed in the catalog.

Executed 2026-09-07 on Linux x86_64 with the candidate's bundled clang. Exact
OS, compiler commit, Node, libc, flags, commands, and elapsed times are retained
in [normalized results](results.txt). The linked libuv version was not
independently measured. No sanitizer was enabled. This is not a performance
benchmark; root could build production concurrently.

## Procedure

Inspect installed candidate TCP and Timer declarations, then compile
[Probe.lean](Probe.lean) directly to C and a standalone native executable. No
Lake invocation or project build is involved. The dependency-free Node
[runner](run.mjs) owns the subprocesses and records diagnostics in `.work/`.

From this assignment directory, set `LEAN_BIN_DIR` externally to the candidate
toolchain's `bin` directory, then run:

```sh
node run.mjs
```

The runner executes these commands with cwd `.work/` and a 120-second timeout
per compile command:

```sh
lean --root=.. -DwarningAsError=true -o Probe.olean -c Probe.c ../Probe.lean
leanc -O2 -o probe Probe.c
```

It then runs `./probe` in three fresh processes, each capped at 40 seconds. Each
process has one listener bound to IPv4 `127.0.0.1:0` with backlog 4 and only one
connected pair at a time. The client connects only to the address obtained from
that owned listener. Each send is one byte; each receive allocates at most eight
bytes. Each test category has 100 iterations:

1. Silent connected peer: assert the read is still pending, cancel three times,
   and require outer `none`, not EOF.
2. Send/cancel completion race: start one sender task, vary sender/canceller
   delays over 0/1/2 ms, and require either outer `none` or exactly byte `x`.
   Require both outcomes to occur within the category.
3. Timer lifecycle: cancel a long one-shot twice, require its dropped result,
   restart and cancel again, then separately fire a short one-shot and verify
   cancellation after completion preserves its finished result.
4. Tagged `IO.waitAny` between receive and timer tasks, for a silent peer,
   fast sender, and near-deadline sender. Explicitly cancel both operations,
   repeat cancellation, and observe both result tasks. Join every sender.

No unresolved producer promises are deliberately retained: noinline helpers
return only their `result?` tasks. The main test action is the sole receive/
cancellation owner; the sender owns only its peer's send. Extra endpoint IO uses
keep both peers alive through result assertions. Cleanup has explicit
`finally` calls to `Socket.cancelRecv` and `Timer.cancel`. Socket references are
dropped after awaited successful sends; neither `Socket.shutdown` nor
`Timer.stop` is called.

FD checkpoint sampling attempts inspect only the spawned probe's `/proc` entry.
All samples failed with `EACCES`; no workaround or unowned process inspection
was attempted. All executable processes exited normally, so no timeout kill or
ambiguous cleanup was needed. On any future compile timeout, the runner reports
failure; do not assume all compiler descendants have exited without checking
their ownership.

## Evidence

### Source contracts

`recv?` forbids parallel receives. Its success result distinguishes data from
EOF. The outer `Promise.result?` option additionally represents destruction of
an unresolved promise. `IO.waitAny` selects a completed result but does not
cancel the loser. One-shot `Timer.cancel` drops the pending promise and resets
the timer to the initial state; it is not `Timer.stop`.

### Implementation observations

The candidate's `lean_uv_tcp_cancel_recv` releases `lean_dec(socket)`, matching
the wrapper retained when starting a receive. This differs from the v4.24 raw
payload decrement documented in the baseline report. Timer and socket
cancellation are explicit operations, not consequences of dropping task handles.
This experiment does not requalify other TCP error/lifetime paths. Additional
source review by the researcher and root's read-only reviewer identified these
limitations in the pinned `tcp.cpp`:

- `lean_uv_tcp_shutdown` retains a socket and two promise references, but its
  immediate `uv_shutdown` error path releases only one promise reference. The
  server avoids this API and closes via the finalizer after awaited sends instead.
- `lean_uv_tcp_listen`'s pending-accept callback omits the listener decrement on
  both its `status < 0` and `uv_accept` error branches; the first also leaves
  `m_client` retained. The promise slot is already cleared, so subsequent
  `cancelAccept` cannot repair it. Listener-error reclamation is not qualified.
- Overlapping `accept` calls can return without unlocking the event loop. The
  server has only one accept owner and never overlaps accepts.
- No explicit abort/close operation is exposed to terminate a stalled send.
  The server retains its admission slot until the worker actually finishes.

These are source observations, not executed fault reproductions. Likewise the
timer probe uses `cancel`, not `stop`: the latter writes its finished state after
unlocking in the inspected implementation. The production timer has one owner.

### Executed tests

The final Lean compile passed with warnings as errors; native compilation used
`-O2`. All three executable runs passed with empty stderr and no timeout.
Exact per-run counters and elapsed times are authoritative in
[results.txt](results.txt); ignored raw diagnostics are in `.work/`.

Across the three executions:

- 300 pending receives produced outer `none`, with repeated cancellation.
- Every direct completion-race result was cancellation or the expected byte;
  both outcomes occurred in each execution.
- Timer cancellation, restart, natural firing, and cancellation after natural
  completion all met their assertions.
- Every silent-peer selection selected the timer and yielded a cancelled read.
- Every fast-read selection selected the receive and yielded a cancelled timer.
- Near-deadline selection exercised both winners and both loser outcomes.

Importantly, in run 2's near-deadline category there were 65 timer winners but
only 64 cancelled reads: one losing receive completed before explicit cleanup.
Receive winners also sometimes had already-fired timer results. A loser is not
necessarily cancelled merely because its result was not selected. The probe
accepts and inspects both legitimate terminal outcomes rather than asserting
that every loser must become `none`.

Diagnostics distinguish two harness limitations from runtime failures:

- The initial compile omitted `--root=..`; Lean rejected a source outside its
  default cwd root before execution. Adding the explicit root fixed this.
- All 21 FD samples failed with permission errors. Process success is not a
  substitute for FD or memory accounting.

### Kernel proofs

None concerning cancellation, resource reclamation, or scheduling. Successful
Lean compilation checks this probe's typing; it is not a proof of its runtime
assertions or of the libuv implementation.

### Actual-server integration (root)

The production [server](../../LeanWeb/Server.lean) uses this pinned runtime and
single-owner result-task/cancellation pattern, but adds its own absolute monotonic
deadline and tracked worker registry. The dependency-free
[TCP suite](../../tests/http.test.mjs) runs the example and a
[test-only fixture](../../tests/TransportMain.lean) through that actual server.
The fixture uses two workers and a 200 ms read deadline, plus bounded slow handlers
and two 16 MiB responses to exercise retained write slots. Both children are owned,
loopback-only, and stopped by the harness. Each suite invocation is bounded to
40 seconds externally; individual top-level tests have 30-second budgets.

Executed assertions cover healthy requests alongside silent/incomplete peers,
40 ms byte drips that cannot refresh the deadline, three overload/recovery cycles,
completed-read timer cleanup, handler slot retention, 24 completion/deadline races,
EOF/malformed completion races, repeated resets and sanitized handler failures,
and actual stalled-write slot retention followed by disconnect recovery.

The executable Lean tests also call the production `responseBeforeDeadline`
selection boundary with deadline zero, requiring both parsed success and parser/
EOF rejection to fail without invoking the handler. A pre-deadline rejection
remains reachable. Temporarily moving the clock check into only the success branch
made this test fail; root restored the correct gate before final verification.
This deterministic check complements TCP races, whose scheduling alone cannot
reliably force late rejection selection.

Unlike the external sampling denied to the isolated probe, the test fixture can
read `/proc/self/fd` itself. After each of three batches mixing timeouts, resets,
and healthy requests, the count returned to baseline (15). This samples descriptors
at quiescent boundaries; it does not establish heap/thread reclamation or a hard
transient resource bound. Exact root checks and elapsed times are recorded in
[results.txt](results.txt).

The upgrade's existing decoder regression caught upstream `toNat?` accepting
underscores. An explicit ASCII-digit guard preserves the previous syntax and
source/controller contracts. The full build kernel-checked the existing proofs;
selected axiom audits and their standard-library dependency changes are recorded
in [Architecture](../../docs/architecture.md#trusted-basis). No cancellation or
resource theorem is inferred from these application proofs.

### Inference

The tested single-owner, task-only, explicit-cancellation pattern is a viable
candidate for the root's receive-deadline slice on this pinned Linux build.
The evidence supports the observed promise outcomes and finite-run process
survival, not general memory safety or hard cleanup latency/resource bounds.

## Conclusion

The compiled candidate passed the bounded receive cancellation and one-shot
timer selection qualification. In particular, the old payload/wrapper mismatch
did not reproduce on these paths, pending cancellation was observably distinct
from EOF, and explicit cancellation made both selected and losing result tasks
observable in the tested runs.

The root's independent TCP suite also passed for the integrated server as recorded
above. This report does not make the server
production-ready and does not establish bounded writes, handler termination,
shutdown completion, or complete socket reclamation.

## Uncertainty

- No FD/memory measurements were obtained for the isolated probe. Root obtained
  server self-FD samples, not memory accounting; no leak-free claim is supported.
- Only short, small-payload Linux x86_64 executions, without sanitizers, were
  performed. Scheduling coverage is finite, not exhaustive.
- EOF and resets are covered by root's server tests, not the isolated probe.
  Allocation failures, accept error branches, abandoned send requests, and
  high-load fairness remain unqualified.
- The isolated selection race covers a receive starting just before a timer
  starts. Root separately tests absolute deadlines across fragmented requests.
- No injected exception tested cleanup between partially initialized operations;
  the production failure path remains an independent obligation.
- The losing read's data can be discarded on timeout; this probe deliberately
  does not attempt connection reuse or claim lossless cancellation.
- Promise finalization depends on reference lifetime. Revalidate if caller
  code retains producer promises or changes task mapping/ownership.
- Repeat qualification after changes to Lean, the transport implementation,
  compiler flags, OS/architecture, or the root's cleanup pattern.

## Follow-ups

Candidate assertions for the root's regression/proof review, not a second plan:

- One active receive owner and no socket reuse after timeout.
- Deadline selection records one decision, but cleanup accepts either completed
  or cancelled losers and never confuses outer cancellation with EOF.
- All producer promise references are released before waiting for cancellation
  results; every sender/worker is joined or otherwise explicitly accounted for.
- Absolute deadlines do not refresh on each fragment, and expired work does not
  newly invoke downstream handlers.
- Capacity remains charged until the actual worker and owned operations finish.
- Test partial setup errors and deadline completion races through the real TCP
  adapter; obtain independent FD/memory evidence in an environment permitting it.

## Artifacts

Only this assignment directory was edited:

- `Probe.lean`: standalone compiled runtime probe.
- `run.mjs`: bounded dependency-free process/diagnostic runner.
- `results.txt`: normalized executed evidence, including harness failures.
- `README.md`: this report.

Generated `.work/` contains C, object/module artifacts, executable, version and
compile stdout/stderr, per-run stdout/stderr, and `results.json`. These are
ignored by the repository's `.work/` rule and must not be committed. Toolchain/source machine paths are not
recorded in the retained report or normalized text.

Reflection candidates: loser completion is separate from winner selection;
resource instrumentation permission failure must remain visible rather than
being interpreted as successful cleanup. Root owns catalog completion and any
integration or durable reflection updates.
