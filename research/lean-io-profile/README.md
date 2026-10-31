# Lean Thread and Event-Loop Profile

## Question

How much of unchanged LeanWeb's request cost is associated with native-thread
startup, task waits, and the libuv event-loop handoff? Profile before choosing
another optimization. Keep production code and the pinned toolchain unchanged.

## References

LeanWeb `6ec5c41`; Lean v4.33.1,
`819816b2e0a3bf405af45ae5c7af2491d8f5bee6`. Prior evidence is in the
[worker investigation](../http-performance/README.md) and
[task-wakeup experiment](../lean-task-wakeup/README.md).

Pinned source paths are
[thread creation](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/thread.cpp),
[task waits](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/object.cpp), and
[event-loop handoffs](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/uv/event_loop.cpp).

The host is Apple M5 with Docker Linux/ARM64. Measurements retain the preceding
benchmarks' two server CPUs, six separate client CPUs, one request per connection,
and validated health responses. The compiler is Clang 22.1.4; C++ headers are from
the matching LLVM release. The distribution pins libuv 1.48.0 in
[flake.nix](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/flake.nix#L77-L89).

## Procedure

Inspect pinned sources. Prefer CPU sampling; if unavailable, use scoped runtime
instrumentation and matched uninstrumented controls. Separate CPU consumption,
blocked wall time, syscall counts, and end-to-end latency. Bound all probes and
retain generated files only in `.work/`.

`perf` software CPU-clock sampling is available in an owned container with
`CAP_PERFMON`; hardware cycle and instruction counters are unsupported by this
VM. Sampling attaches only to the server process and inherits its new threads,
not other host processes. Each of three runs warms for three seconds, records
eight seconds at 997 Hz with DWARF call stacks, and runs six seconds of health
traffic at 32 clients inside that window.

Sampling has a known short-thread bias: a connection worker may exit before its
CPU-clock sampling interval. Sample percentages therefore are not a complete
CPU-time budget. They are complemented by scoped runtime counters rather than
being treated as conclusive attribution.

The diagnostic build adds [scopes](runtime.patch) and a
[counter collector](profile.hpp), without changing HTTP or task scheduling
decisions. `CLOCK_THREAD_CPUTIME_ID` records CPU time; `CLOCK_MONOTONIC` records
wall time. Event-loop acquisition and task-resolution scopes measure only wall
time. SIGUSR1 prints bounded snapshots using lock-free atomic loads and `write`;
the runner subtracts snapshots around each load trial. Samples are not atomic
across fields. Clock or output errors terminate the diagnostic process.

| Scope | Meaning and overlap |
| --- | --- |
| `thread_create` | Inside the pthread-based `lthread::imp` constructor, including `pthread_create`; excludes the new thread's work |
| `thread_entry` | Completed native-thread entry, including its request, waits, signal-stack setup, and teardown; excludes pthread/kernel cleanup after return and unfinished long-lived threads |
| `thread_finalize` | Lean thread-local finalizers, nested inside `thread_entry` |
| `stack_setup`, `stack_teardown` | Alternate signal-stack allocation and registration, nested inside `thread_entry` |
| `loop_acquire_fast`, `loop_acquire_contended` | Acquisition of the shared libuv mutex; contended calls also interrupt the loop |
| `loop_iteration` | One event-loop iteration, including poll, callbacks, and task resolution |
| `task_wait`, `task_wait_any` | Runtime waits, including mutex/condition-variable time; nested in their calling thread |
| `task_resolve` | Resolution and dependent-task propagation, nested in the resolving thread |

Builds use the upstream `leanrt` Make target with warnings as errors. Only
`object.cpp.o`, `thread.cpp.o`, `stack_overflow.cpp.o`, and `event_loop.cpp.o`
replace their release archive members; the other runtime and application
objects remain unchanged. `baseline` rebuilds these four modules without
instrumentation; `profile` adds the scopes. Matched trials quantify observer
overhead rather than assuming the counters are free.

Each measured process warms for three seconds, then serves six-second health
workloads at concurrency 1, 32, and 128. Three repetitions alternate the two
variants. The same task, executable, and 28 TCP regressions run against both.
Builds and distinct profiling experiments do not overlap.

Reproduce the Linux experiments from the repository root:

```sh
node research/lean-io-profile/run.mjs build
node research/lean-io-profile/run.mjs test
node research/lean-io-profile/run.mjs perf
node research/lean-io-profile/run.mjs measure
node research/lean-io-profile/summarize.mjs
```

The Dockerfile requires the previously prepared, digest-pinned Lean base image;
this repository does not publish it. Downloads, compiler inputs, and outputs
remain under `.work/`. Builds have a 180-second child budget; load commands have
30 seconds, and the TCP regression has 40 seconds.

For the optional macOS cross-check, put the pinned `lean` and `lake` on `PATH`,
then run these separately from any Linux measurement:

```sh
node research/lean-io-profile/native.mjs build
node research/lean-io-profile/native.mjs test
node research/lean-io-profile/native.mjs measure
node research/lean-io-profile/summarize.mjs --native
```

The native build uses a fresh workspace rather than copying Linux `.lake`
artifacts. The client source is the existing Go validator with a loopback-port
argument and atomic request-budget guard; successful-response validation is
unchanged. Native process CPU is sampled with `ps`, at coarser resolution than
the Linux process counters. Both platforms keep their existing server code.

## Evidence

### CPU sampling

Three successful recording runs completed in 53.71 seconds, validating 231,525
responses without errors. They contain 7,419 samples with no reported lost
samples. Every sample belongs to the same two long-lived threads within its
run, not the tens of thousands of per-connection workers. This confirms the
short-thread coverage problem for this sampling configuration.

Unresolved kernel instruction pointers account for 5,894 samples (79.4%).
Available user stacks include task-completion broadcasts, mutex operations,
thread creation, and socket I/O. The kernel symbol map was unavailable to these
recordings. These observations locate activity but cannot establish that 79.4%
of total server CPU is spent in the kernel, nor that any one visible function
dominates all threads.

The sampled server sustained 12,834–12,890 requests/s. Sampling is therefore
reported separately from uninstrumented throughput, not as an optimization.
An initial recording attempt was excluded after its post-processing command
used an unsupported option; the reported runs use the corrected collector.

### Scoped measurements

Eighteen Linux trials completed in 149.28 seconds with 1,268,231 validated
responses and zero errors. Values are medians of three trials:

| Clients | Original rebuild req/s | Instrumented req/s | Original CPU μs/request | Instrumented CPU μs/request |
| --- | ---: | ---: | ---: | ---: |
| 1 | 7047 | 7059 | 129.62 | 134.59 |
| 32 | 14277 | 14017 | 89.27 | 93.43 |
| 128 | 14241 | 13986 | 89.75 | 93.76 |

At 32 clients, instrumented median throughput was 1.8% lower and measured
process CPU per response was about 4.2 μs higher. The following
scope timings describe the instrumented execution, not exact uninstrumented costs.

| Scope at 32 clients | Calls/request | CPU μs/request | Mean elapsed μs/call |
| --- | ---: | ---: | ---: |
| Thread constructor | 1.000 | 8.14 | 9.05 |
| Completed thread entry | 1.000 | 50.99 | 279.60 |
| Event-loop iteration | 1.317 | 15.21 | 58.47 |
| Fast event-loop acquisition | 6.849 | not measured | 0.037 |
| Contended event-loop acquisition | 3.151 | not measured | 28.80 |
| `wait_for` | 1.586 | 8.36 | 71.27 |
| `wait_any` | 1.000 | 6.39 | 75.51 |
| Task resolution | 5.998 | not measured | 2.51 |
| Signal-stack setup | 1.000 | 0.64 | 1.08 |
| Signal-stack teardown | 1.000 | 0.45 | 0.72 |
| Lean thread-local finalizers | 1.000 | 0.22 | 0.59 |

These rows are not additive. In particular, wait and signal-stack scopes overlap
thread entry, and resolution can overlap the event loop. The constructor scope
does not include thread-exit kernel work after entry returns. The constructor's
measured CPU cost is one part of the profile, not a complete explanation. Removing
it can also change contention, so its end-to-end impact still needs measurement.
Signal-stack allocation is a small observed component, not a reason to remove
overflow protection.

There are about ten explicit event-loop acquisitions per request, three of them
contended. At 128 clients the counts and per-call timings are similar. The
instrumented worker's mean elapsed lifetime is about 0.28 ms at 32 clients;
the client's request latency also includes connection establishment and waiting
before that worker begins. This does not identify the location of all queueing.

### Native macOS cross-check

The installed native Lean reports the same v4.33.1 revision, targeting
`arm64-apple-darwin24.6.0`. The native Go client compiler is 1.26.3, compared with
1.26.4 in Docker; the host runs macOS 27.0.1. Native measurements are not pooled
with Linux measurements. Native runs have neither Linux CPU affinity nor its cgroup
quotas. The client is restricted to six Go scheduler processors, not six
exclusive physical CPUs.

The first three-second native warmup returned 1,655 client address-allocation
errors after 16,996 successful responses. A fresh destination port alone did
not remove the problem. The configured ephemeral range was 49152–65535, with
TCP MSL 15000 ms. These failed warmups are excluded from throughput comparisons.
Even a one-second trial could exceed the available address budget. The final
protocol caps each 32-client batch at 8,000 attempts, caps warmup at 256 requests,
uses a fresh owned listener, and waits `2 × MSL + 5 seconds` between batches.
The three-second duration is an upper bound, not a required run length. No
sysctl is changed. Listener ownership is checked before any connection attempt.

The three bounded batches completed 24,000 validated requests with no errors:

| Batch | Requests | Elapsed seconds | Requests/s | p99 ms | Server CPUs |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 8000 | 0.514 | 15561 | 2.920 | 2.55 |
| 2 | 8000 | 0.484 | 16527 | 2.275 | 2.56 |
| 3 | 8000 | 0.559 | 14305 | 2.506 | 2.50 |

Median native throughput was 15,561 requests/s, with median p99 2.506 ms.
The run took 109.75 seconds including cooldowns. These are short bursts, not
sustained throughput trials. Native execution remained around 15 thousand
requests/s here; the differing durations, CPU limits, kernel, and client build
prevent attributing a precise difference to Docker.

The native parse/handle/render probe took a median 3.80 μs per operation over
three 100,000-operation repetitions. As with the earlier Linux probe, this is
a small-request pure-pipeline measurement, not a complete server profile.

### Checks and proof boundary

The original-source and instrumented runtime targets built with C++ warnings as
errors. Both passed the existing task/cancellation/shutdown probe, executable
suites, and all 28 TCP tests. No new kernel theorem was proved, and no production
source or installed runtime was changed.

The separate native build and executable suites passed. Its TCP suite passed
27 tests and skipped the Linux-only descriptor-count test. Native client
generation was checked with `gofmt`, `go build`, and `go vet`.

Archive inspection confirmed that only the four intended runtime objects were
replaced. A final reproduction produced byte-identical copies of all 12 Linux
executables used for the tests and measurements. The root 69-job build passed.

## Conclusion

**Repeated transport coordination is a stronger optimization target than thread
construction alone.** The profile records ten loop acquisitions per request,
about three contended handoffs, and CPU work in task waits and event-loop
processing. The short-lived request worker is the largest measured execution
region, but its internal cost is not fully attributed by this experiment.

The measurements do not establish a complete explanation of the Java comparison.
They do rule out treating the observed constructor CPU cost as the entire cost
of a request, and the native cross-check does not remove the throughput gap by
simply leaving Docker. Keep the current server and toolchain until a candidate
improves the intended latency and throughput metrics in matched trials.

## Uncertainty

Profiling perturbs scheduling. Summed blocked times can overlap and are not CPU
cost or independent portions of a request's latency. A local profile is not a
general performance or correctness guarantee.

The runtime counters add clock reads and atomic updates, including inside locks.
Neither their timings nor CPU-clock samples should be extrapolated to an exact
uninstrumented cost breakdown. Completed scopes can cross snapshot boundaries.
The unchanged parser and proof contracts do not verify the profiling code or
the transport. No full upstream compiler build or sanitizer qualification is
claimed.

## Follow-ups

The smallest follow-up is to combine the already tested persistent-worker
prototype with the targeted-wakeup runtime and measure that interaction. Its
long-lived workers would also remove the short-thread sampling blind spot.
This is cheaper to investigate than immediately replacing the event-loop bridge.

A loop-owned I/O command queue is a larger candidate that targets the measured
handoffs, but it adds ownership, cancellation, and shutdown obligations. Either
candidate must preserve admission and deadline semantics and pass the existing
effect, cancellation, disconnect, and TCP checks. No speedup is established for
either combination by this report.

## Artifacts

Sources and normalized data belong here. Downloaded sources, build artifacts,
raw profiles, and diagnostics belong in `.work/`.

The executable procedure is [run.mjs](run.mjs), [native.mjs](native.mjs),
[prepare.mjs](prepare.mjs), [build.mjs](build.mjs), and [summarize.mjs](summarize.mjs).
Instrumentation is [runtime.patch](runtime.patch) and [profile.hpp](profile.hpp).
Normalized evidence is [results.csv](results.csv), [scopes.csv](scopes.csv),
[sampling.json](sampling.json), [native.csv](native.csv), and
[native-pipeline.json](native-pipeline.json). Runtime source hashes and archive
checks are in [build-inputs.json](build-inputs.json). No production API, proof
contract, or roadmap ordering changed.
