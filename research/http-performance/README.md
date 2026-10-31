# HTTP Performance Investigation

## Question

Which changes can improve the measured LeanWeb throughput plateau without
discarding parser, deadline, admission, or handler-isolation contracts?
Production code remains unchanged. This assignment tests research-only variants.

## References

Baseline: LeanWeb `55d8c02`, with the same production implementation measured in
the [throughput baseline](../http-throughput/README.md). Lean v4.33.1, commit
`819816b2e0a3bf405af45ae5c7af2491d8f5bee6`.

Pinned upstream sources:

- [Dedicated tasks and task waits](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/object.cpp#L789-L1059).
- [Native thread creation](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/runtime/thread.cpp#L139).
- [Channel implementation](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/Std/Sync/Channel.lean).
- [Mutex and condition-variable contracts](https://github.com/leanprover/lean4/blob/819816b2e0a3bf405af45ae5c7af2491d8f5bee6/src/Std/Sync/Mutex.lean).

The host, Lean image, client compiler, resource limits, and connection-close
workloads match the earlier baseline: Apple M5, Docker Linux/ARM64, two server
CPUs and six separate client CPUs, Go 1.26.4. The [runner](run.mjs) pins the Lean
and Go images. The diagnostic image adds Debian `strace` 6.1-0.1; it is not used
for untraced throughput measurements.

## Procedure

Inspect the pinned runtime, count native-thread creation under bounded tracing,
time the pure request pipeline, and compare the original server with a bounded
persistent-worker variant. Reuse the existing benchmark's client and matched
Docker resource limits; keep tracing separate from throughput measurements.

[prepare.mjs](prepare.mjs) copies source and build artifacts into independent
`.work/` workspaces. Both variants keep the original parser, renderer, read loop,
deadline checks, receive/timer cleanup, and handler exception boundary. Only
worker admission and reuse change:

- `baseline`: the unchanged server starts one dedicated task per connection.
- `pool`: 32 persistent dedicated workers use promise-backed channels for jobs
  and available slots.
- `native`: 32 persistent dedicated workers use mutex-protected single-slot
  inboxes and targeted condition-variable notifications. Available workers are
  selected in LIFO order. The dispatcher obtains a free slot before accepting,
  records the deadline at accept, and returns the slot after `respond` finishes.

Both candidate server implementations are Lean. The fragments are not standalone modules;
the preparation script inserts them after the original server's IO helpers.
They are prototypes, not approved production replacements.

Reproduce from the repository root:

```sh
node research/http-performance/run.mjs build
docker build -t leanweb-http-profile:lean-4.33.1 research/http-performance
node research/http-performance/run.mjs pipeline
node research/http-performance/run.mjs trace
node research/http-performance/run.mjs screen
node research/http-performance/run.mjs measure
node research/http-performance/summarize.mjs
```

Builds have a 120-second command budget. Socket clients have the existing
three-second dial and connected-socket deadlines; load commands have a
45-second outer budget. Each traced server stops after eight seconds, including
three seconds of measured traffic. Tracing includes startup and readiness
requests. It changes scheduling substantially and is used for syscall counts,
not throughput or CPU-time comparisons.

Screening uses three fresh server processes per variant, a one-second warmup,
and a two-second health measurement at concurrency 32. The longer comparison
uses three fresh processes per selected variant, alternating baseline/candidate
order, five seconds of health and three seconds of echo warmup, then eight-second
measurements. Health concurrency is 1, 32, and 128; echo uses 32 clients and 1 KiB
bodies. Every response is validated by the existing [client](../http-throughput/client.go).
No builds or other benchmarks run concurrently with these measurements.

The pure probe runs 100,000 operations per phase, repeated three times in one
process. Requests vary a small query value, and rendering varies a two-character
JSON string while retaining the 15-byte body size. Results feed checksums to
prevent unused work; varying render input avoids lifting a closed rendering
expression out of the loop. Timings include loop and checksum overhead. The
probe is not a profile of arbitrary requests or controllers.

## Evidence

### Source contracts and implementation

`LeanHttp/Server.lean` starts a `.dedicated` task after every accept. The pinned
runtime's `enqueue_core` calls `spawn_dedicated_worker` for that priority, which
constructs an `lthread`; its Linux implementation calls `pthread_create`.
Dedicated tasks are not drawn from the reusable standard worker pool.

The runtime resolves tasks with a shared condition variable and `notify_all`.
Its blocking `wait_for` and `wait_any` use that condition variable. Consequently,
many idle workers waiting for promise-backed channel receives are exposed to
unrelated task completions. `wait_for` can grow the standard pool when called
from a standard worker; `wait_any` has no corresponding adjustment. Changing
the connection tasks to ordinary shared-pool tasks is therefore not a qualified
substitute for preserving dedicated-worker isolation.

`Std.Mutex.atomicallyOnce` holds the mutex while checking its predicate, waits
with the mutex released, and rechecks after waking. The native candidate uses
that API and `Condvar.notifyOne`, not unsynchronized flags or polling.

### Executed evidence

The pure pipeline, syscall counts, screening, and longer comparison are separate
experiments. All were executed on 2026-10-31.

The corrected pure probe measured these per-operation times, including its loop
and checksum overhead:

| Phase | Median microseconds | Range |
| --- | ---: | ---: |
| Parse short health request | 2.946 | 2.941–3.109 |
| Framework health dispatch | 0.050 | 0.050–0.055 |
| Render varying 15-byte response | 0.103 | 0.102–0.103 |
| Parse, handle, render | 3.120 | 3.098–3.123 |

The syscall experiment confirms native-thread churn in the baseline. Counts
include startup, readiness traffic, and the three-second traced workload:

| Variant | Accepted requests | Native-thread creation calls | Futex calls |
| --- | ---: | ---: | ---: |
| Baseline | 3793 | 3795 | 189163 |
| Promise-backed pool | 1368 | 38 | 560438 |
| Targeted-wakeup pool | 4743 | 34 | 211990 |

These counts support the distinction between thread reuse and wakeup behavior.
They do not assign a fraction of untraced CPU time to either mechanism. In
particular, cumulative futex wait time is not CPU consumption.

Short screening rejected the promise-backed design: at 32 clients, median
throughput was 6378 requests/second versus 13706 for its paired baseline. The
targeted-wakeup pool reached 15653. Each screening result is a median of three
two-second trials, not the longer result below.

The longer comparison completed **24 trials with 2,492,723 validated responses
and zero errors** in 260.25 seconds. Values are medians of three trial values;
throughput ranges show all trials. CPU is in whole-CPU equivalents, and RSS is
post-trial resident memory, not peak allocation.

| Workload | Clients | Variant | Req/s median (range) | p50 ms | p99 ms | Server CPUs | RSS MiB |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| health | 1 | Baseline | 6976 (6835–7012) | 0.146 | 0.195 | 0.91 | 42.0 |
| health | 1 | Targeted pool | 7310 (7254–7348) | 0.136 | 0.184 | 0.72 | 39.8 |
| health | 32 | Baseline | 14206 (14150–14321) | 2.201 | 3.853 | 1.27 | 46.1 |
| health | 32 | Targeted pool | 15925 (15154–16055) | 1.858 | 6.152 | 1.10 | 45.0 |
| health | 128 | Baseline | 14210 (14106–14249) | 8.832 | 13.581 | 1.27 | 46.5 |
| health | 128 | Targeted pool | 16135 (15259–16214) | 7.463 | 16.422 | 1.11 | 44.0 |
| echo | 32 | Baseline | 14031 (13775–14126) | 2.242 | 3.211 | 1.29 | 46.5 |
| echo | 32 | Targeted pool | 15966 (14804–16020) | 1.936 | 3.507 | 1.13 | 32.4 |

At 32 health clients, targeted reuse improved median throughput by **12.1%** and
reduced median CPU-seconds per request by **22.4%**, but its median p99 was
**59.7% worse**. Peak process RSS across the longer runs was 66.6 MiB for the
baseline and 75.6 MiB for the targeted pool. Peak RSS includes startup, warmup,
and preceding workloads in each process; it is not directly comparable to the
post-trial RSS column. All screening trials also completed without errors.

Per-trial values are in [results.csv](results.csv); raw pure-probe values and
normalized syscall counts are in [diagnostics.json](diagnostics.json).

Both worker-reuse prototypes built with warnings as errors and passed the
existing executable suites and all 28 TCP tests in their isolated workspaces.
Those tests cover slow peers, absolute deadlines, effect counts, admission
backpressure, handler errors, resets, stalled writes, and descriptor recovery.
No new worker-pool invariant, trace equivalence, or resource-safety theorem was
proved; the existing wire definitions and their proofs were not changed.

## Conclusion

**Keep the current worker implementation for now.** Reusing dedicated workers
can reduce CPU cost and modestly improve throughput, but this prototype does
not improve every latency measure and adds persistent threads, handoff state,
and shutdown obligations. It does not justify a default change based on
throughput alone.

The smallest textual change, replacing `.dedicated` with a shared-pool priority,
is not a qualified alternative: it changes blocking and isolation behavior.
The promise-backed persistent pool is worse in the measured workload and should
not be used as the optimization.

The next useful experiment is a transport path that avoids blocking waits and
repeated thread handoffs for socket progress, while keeping arbitrary blocking
handlers in bounded workers. That is a larger design change, and no speedup is
claimed for it here. It needs its own admission, deadline, cancellation, and
effect tests before production integration.

Do not start by removing proofs, weakening validation, caching tiny health
responses, or rewriting routing: the measured short-request parse/handle/render
pipeline is about 3.1 microseconds. That does not explain the whole transport
gap. Larger or fragmented requests could justify separate parser-progress work,
but this experiment supplies no performance result for that workload. Keep-alive
would change the currently supported HTTP subset and is not a drop-in refactor.

## Uncertainty

An isolated speedup does not qualify a production change. Worker reuse must
preserve admission timing, request deadlines, error isolation, and cleanup;
socket and runtime correctness are not established by a performance test.

Worker reuse introduces eager idle threads, shared handoff state, shutdown
coordination, and reusable thread-local state. The current server creates workers
on demand. Tests of normal shutdown, listener failure, arbitrary handler-created
tasks, and all race schedules remain incomplete. The prototypes preserve the
existing absence of handler/write deadlines; they do not complete the operational
server gate.

The short pure pipeline uses small valid requests and a constant health response;
its costs do not bound larger or fragmented input. No sampled CPU or allocation
profile was collected. Syscall wait time is not CPU utilization, and traced
throughput must not be compared with the untraced baseline.

## Follow-ups

Use measured costs and regression results to recommend the smallest worthwhile
production change, with its remaining verification obligations. For worker reuse,
require a paired improvement in the intended latency/CPU metric, not only peak
throughput, plus explicit worker ownership and shutdown invariants. The targeted
pool's tail-latency regression remains unresolved.

## Artifacts

Sources are [prepare.mjs](prepare.mjs), [run.mjs](run.mjs),
[PipelineMain.lean](PipelineMain.lean), [pool-body.lean](pool-body.lean),
[native-body.lean](native-body.lean), [Dockerfile](Dockerfile), and
[summarize.mjs](summarize.mjs). Generated workspaces, raw profiling output,
compiled artifacts, and downloaded source copies stay in `.work/`. Durable data
are [results.csv](results.csv) and [diagnostics.json](diagnostics.json). No
production implementation, public API, proof contract, or roadmap order changed.
