# Targeted Lean Task Wakeups

## Question

Does notifying only the waiters interested in a completed task improve unchanged
LeanWeb performance? Compare the pinned runtime with an identically rebuilt
candidate. Do not change application sources, APIs, or the production toolchain.

## References

Lean v4.33.1, commit `819816b2e0a3bf405af45ae5c7af2491d8f5bee6`;
LeanWeb `9b57f87`. The preceding [investigation](../http-performance/README.md)
identified shared task-completion broadcasts and native-thread churn as separate
costs. This experiment addresses notifications, not dedicated-thread reuse.

- [Task implementation](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/object.cpp).
- [Runtime build target](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/CMakeLists.txt).
- Compiler and C++ headers: Clang/libc++ 22.1.4, LLVM revision
  `35990504507d79e0b9deb809c8ee5e1b34ceef20`.
- GMP headers: 6.3.0. Runtime linking retains the release's GMP, libuv, OpenSSL,
  libc++, and all other library objects.
- Apple M5 host, Docker Linux/ARM64. Two server CPUs and six separate client
  CPUs; Go 1.26.4 client, connection close after each response.

## Procedure

The [patch](runtime.patch) adds a task-to-waiter registry to the task manager.
Each blocking caller owns one condition variable and registers the tasks it
awaits. Completion notifies every registered caller for that task. `waitAny`
registers all candidates and removes all registrations before returning,
including duplicates and unfinished losers. Registration, notification, and
removal use the existing task-manager mutex. Predicate checks remain in loops;
task cancellation, dependency scheduling, and dedicated-thread creation do not
change.

Build the original and patched `leanrt` targets with the same CMake-generated
Makefiles, using `make -j4 -C build/release leanrt`. Both compile with C++20,
`-O3`, `-Wall -Wextra -Werror`, multithreading, and local-exec thread-local storage.
Only `object.cpp.o` from each build replaces the corresponding member of a copy
of the release runtime archive. Archive comparison rejects changes to any other
member. Relink the same application and test objects against each archive using
the original Lake response files; no Lean source recompilation or alternate
HTTP implementation distinguishes the measured variants.

The release executable is a third control (`stock`). The original-source rebuild
is `baseline`; the notification patch is `patched`. This distinguishes patch
effects from build-configuration effects. Link maps and archive/source hashes
are retained in `.work/`. This is a runtime-target build and executable relink,
not a full Lean compiler/bootstrap build or the complete upstream test suite.

Reproduce from the repository root:

```sh
node research/lean-task-wakeup/run.mjs build
node research/lean-task-wakeup/run.mjs test
node research/lean-task-wakeup/run.mjs screen
node research/lean-task-wakeup/run.mjs trace
node research/lean-task-wakeup/run.mjs measure
node research/lean-task-wakeup/summarize.mjs
```

The Dockerfile uses the same locally prepared, digest-pinned Lean base image as
the earlier benchmarks. It must already be available; this repository does not
publish that image. Its required tools are the pinned Lean toolchain (including
Clang and static runtime libraries), Node.js 22+, and native C/C++ build tools.

Build commands run in Docker with four CPUs, 4 GiB RAM, and a 180-second child
budget. The client validates status, framing, and response body. Screening uses
three fresh processes per variant, one-second warmup and two-second measurements
at 32 health clients. Longer measurements use five fresh processes per selected
variant, alternate execution order, warm health for five seconds and echo for
three seconds, and measure each workload for eight seconds. Health uses 1, 32,
and 128 clients; echo uses 32 clients with 1 KiB bodies. No build or other
benchmark runs concurrently with a measurement.

Tracing has an eight-second server budget and three seconds of health traffic
at 32 clients. Counts include startup and readiness traffic. It is separate
from untraced measurements; traced timings are not performance estimates.

The [task probe](TaskProbe.lean) covers precompleted tasks, multiple callers,
duplicate and overlapping `waitAny` candidates, disjoint completions, pending
producer abandonment, cooperative cancellation, standard-pool waits, synchronous
dependencies, racing completions, and cooperative shutdown. Each variant runs
the normal probe and shutdown mode five times, plus the existing executable and
28 TCP tests. Each probe process has a 30-second budget; the TCP suite has 40.

## Evidence

### Source inspection

The original `resolve_core` broadcasts on one condition variable shared by
`wait_for` and `wait_any`. The candidate keeps their completed-task fast paths
and the existing `wait_any_check` list traversal. Its stack-owned registration
survives spurious wakes and is removed while the mutex is still held. Registration
is a separate operation after construction, so partial registration can be removed
if allocation throws. This reasoning is a source review, not a formal proof.

Cancellation semantics do not change: `IO.cancel` sets the cooperative flag;
it does not by itself complete a task being awaited. Dropping the last unresolved
promise producer still resolves its result task to `none` and uses the same
notification path as successful resolution.

### Executed checks

Both runtime variants built with C++ warnings as errors. Archive inspection found
35 members and verified that only `object.cpp.o` differed from the release archive.
Link maps select the experimental archive, and the patched server contains the
new scoped-waiter symbol. The unchanged root build completed all 69 jobs.
A final reproduction produced byte-identical copies of all 12 tested executables.

All three variants passed five task-probe runs, five cooperative-shutdown runs,
the existing executable suites, and all 28 TCP tests, with no skips. Tests set
`LEAN_NUM_THREADS=2`; the eight standard-pool waiters therefore also exercise
the existing blocked-worker compensation path. The final regression run took
43.64 seconds. Each regular probe includes 30 groups of 24 shared waiters and
1,000 completion races. Timed sleeps encourage interleavings; they do not ensure
every waiter was blocked before completion.

The three short screening trials gave median health rates of 14,138 requests/s
for the release executable, 14,324 for the original-source rebuild, and 15,616
for the patch. The original rebuild did not introduce a large throughput change
in this control. Screening is not a substitute for the longer comparison.

The syscall trace covered the following startup, readiness, and health traffic:

| Runtime | Accepted requests | Native-thread creation calls | Futex calls | Futex calls/request |
| --- | ---: | ---: | ---: | ---: |
| Original rebuild | 4125 | 4127 | 204467 | 49.6 |
| Targeted notifications | 4426 | 4428 | 154427 | 34.9 |

Synchronization calls per request fell by about 30%, while native-thread
creation stayed near one per request. Futex counts include both mutex and
condition-variable operations; they are not a count of spurious wakes or a
measurement of CPU time. Tracing changes scheduling and throughput substantially.

The longer comparison completed **40 trials with 4,115,310 validated responses
and zero errors** in 432.20 seconds. Values below are medians of five trials;
the throughput ranges include every trial. CPU is in whole-CPU equivalents;
RSS is resident memory after the trial, not peak allocation.

| Workload | Clients | Runtime | Req/s median (range) | p50 ms | p99 ms | Server CPUs | RSS MiB |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| health | 1 | Original rebuild | 6976 (6948–7246) | 0.146 | 0.197 | 0.91 | 38.3 |
| health | 1 | Targeted notifications | 8032 (7745–8155) | 0.120 | 0.191 | 0.91 | 48.1 |
| health | 32 | Original rebuild | 14165 (13759–14231) | 2.207 | 3.790 | 1.27 | 42.1 |
| health | 32 | Targeted notifications | 15488 (14339–15644) | 1.866 | 7.292 | 1.25 | 48.5 |
| health | 128 | Original rebuild | 14221 (13730–14254) | 8.840 | 12.484 | 1.27 | 48.5 |
| health | 128 | Targeted notifications | 15757 (14408–16030) | 7.498 | 20.212 | 1.27 | 64.8 |
| echo | 32 | Original rebuild | 14055 (13256–14077) | 2.255 | 3.236 | 1.29 | 48.5 |
| echo | 32 | Targeted notifications | 15270 (14697–15580) | 1.920 | 5.149 | 1.27 | 64.8 |

At 32 health clients, median throughput increased **9.3%**, server CPU time per
response fell **10.4%**, and p99 latency increased **92.4%**. At one client, throughput
increased 15.1% without a median p99 regression. Peak process RSS over all longer
trials was 66.5 MiB for the original rebuild and 68.6 MiB for the patch. Peak RSS
also includes startup, warmup, and preceding workloads; the post-trial RSS column
cannot identify which allocation paths explain the difference.

The client's median CPU use at 32 health clients rose from 0.71 to 1.50 CPUs,
within its six-CPU allocation. No whole-system CPU saving is claimed. One patched
echo trial included a 1.011-second request; the longest observed original-run
request was 47 ms. The cause of these latency and client-cost differences is
unresolved.

All nine screening trials also completed without errors. Per-trial measurements
are in [results.csv](results.csv); normalized tracing and build provenance are in
[diagnostics.json](diagnostics.json).

### Kernel proofs

No C++ runtime property was kernel-proved. The existing Lean source and proof
contracts were not changed; their usual build check does not verify this patch.

## Conclusion

**The upstream patch helps throughput, but is not a clear replacement for the
current runtime.** The unchanged application sustains about 9–15% more requests
per second on these workloads, so part of its cost can be reduced in Lean's
runtime source. The concurrent workloads' median p99 latency worsens, and the
experiment does not explain the full gap to other HTTP implementations.

Keep LeanWeb's pinned toolchain unchanged. This candidate is useful evidence for
an upstream performance discussion, not a production fix or a generally faster
Lean runtime. No upstream issue, pull request, or release was published.

## Uncertainty

Passing finite tests cannot establish general scheduling, cancellation, lifetime,
or shutdown correctness. Results apply to the pinned Linux/ARM64 runtime and
bounded local workloads, not every Lean application or platform.

This experiment does not run Lean's complete upstream suite, rebuild its compiler
or standard libraries, or qualify a new release toolchain. Sanitizers, allocation
failure injection, Windows/macOS behavior, and large compiler workloads remain
untested. The registry adds allocation and hash-table work to blocking waits;
benefits and costs may differ when few threads wait or wait lists are large.
Existing global task-manager locking and per-connection thread creation remain.

The cause of the p99 regression has not been profiled. Five trials per workload
on one shared development host do not establish performance across hardware or
workloads. The release-versus-rebuild control used only short health screening,
not the entire longer workload matrix.

## Follow-ups

Profile delayed requests before changing notification or scheduling policy again.
If pursuing an upstream proposal, qualify the complete compiler/runtime build,
the upstream task tests, sanitizers, and other supported platforms. A separate
experiment could combine this patch with the earlier promise-backed worker pool;
that combination was not measured here.

## Artifacts

Runtime patch, probes, and normalized results belong here. Downloaded upstream
source, private toolchains, binaries, and raw diagnostics stay in `.work/`.

Sources are [runtime.patch](runtime.patch), [TaskProbe.lean](TaskProbe.lean),
[build.mjs](build.mjs), [fetch.mjs](fetch.mjs), [prepare.mjs](prepare.mjs),
[run.mjs](run.mjs), [summarize.mjs](summarize.mjs), and [Dockerfile](Dockerfile).
Production Lean code, public APIs, proof contracts, and roadmap order are unchanged.
