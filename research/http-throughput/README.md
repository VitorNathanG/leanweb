# HTTP Throughput Baseline

## Question

What latency, throughput, and resource use does unchanged LeanWeb exhibit against
Node.js HTTP, Go `net/http`, and Spring Boot on the same bounded loopback workload?
This measures the existing server, not a proposed dispatch state machine.

## References

LeanWeb baseline: `a7be3f6330912e6c2ccf57f5dff057cb1455d33b`, Lean v4.33.1.
The benchmark uses its unchanged `leanweb` executable, including the example's
router and body-limit middleware. No state-machine implementation is included.

| Implementation | Version and configuration |
| --- | --- |
| LeanWeb | Lean 4.33.1, `819816b2e0a3bf405af45ae5c7af2491d8f5bee6`; `lake build leanweb`; default server configuration, including 32 workers |
| Node HTTP | Node 22.23.1; one process, no cluster or framework; [handler](server.mjs) |
| Go net/http | Go 1.26.4; `go build -trimpath`; standard library, no framework; [handler](server.go) |
| Spring MVC | Spring Boot 4.1.2, Spring Framework 7.0.10, Tomcat 11.0.27; Temurin 21.0.7+6; `-Xms64m -Xmx512m -XX:-UsePerfData`; [application](spring/src/main/java/benchmark/BenchApplication.java) |

Image digests are pinned in [run.mjs](run.mjs). The Lean image must provide the
pinned toolchain and C build tools; `LEAN_BENCH_IMAGE` can select an equivalent
locally prepared image. The measured image's digest is recorded in that script.
The other images are published Node, Go, and Maven images.

Public version references:
[Lean](https://github.com/leanprover/lean4/releases/tag/v4.33.1),
[Node](https://nodejs.org/download/release/v22.23.1/),
[Go](https://go.dev/dl/#go1.26.4), and
[Spring Boot](https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-dependencies/4.1.2/).

Environment: Apple M5 host, 10 CPU cores, 32 GiB RAM; Docker Desktop Engine
29.8.2, Linux `7.0.14-linuxkit`, ARM64, with 10 virtual CPUs and 8,319,504,384 bytes
of VM memory. These are local virtualized measurements, not bare-metal results.

## Procedure

Use Docker Linux/ARM64, two server CPUs and six separate load-generator CPUs,
with sequential server runs and no published ports. GET `/health` returns the
same 15-byte JSON body; POST `/echo` returns 1024 ASCII bytes. Each request opens
a new TCP connection and requires a fixed Content-Length and connection close.
Validate every response's status, content type, length, and body.

Measure closed-loop concurrency 1, 8, 32, and 128 for health, and 32 for echo.
For each of three rounds, start a fresh process for each implementation. Rotate
implementation and workload order between rounds. Warm up each process for 15
seconds of health traffic and 5 seconds of echo traffic, both at concurrency 32.
Measure each workload for 8 seconds, including draining outstanding requests in
the reported elapsed time. Startup and warmup are excluded from the results.

Servers use CPU affinity `0,1`, a two-CPU quota, 2 GiB memory without swap,
and a 1024-task limit. The load generator uses affinity `2–7`, a six-CPU quota,
1 GiB memory without swap, and a 256-task limit. Both allow 65,536 open files.
The server and client containers share an isolated, loopback-only network
namespace. Linux `tcp_tw_reuse=2` and ephemeral ports `32768–60999` are unchanged.
Affinity separates virtual CPUs; it does not reserve physical host cores.

The [Go client](client.go) measures from before dialing through response-body
validation and client-side close. It stops starting requests after the duration,
waits for outstanding requests, and fails on any bad response or network error.
Dial and connected-socket timeouts are three seconds each. This is a closed-loop
test: each worker starts its next request only after the previous one finishes.

Throughput is successful requests divided by elapsed time. Summary throughput
and latency percentiles are medians of three trial values, not a pooled latency
distribution. Throughput ranges show all three trials. CPU values are mean
process CPU-seconds per wall second: `1.0` means one busy CPU. Server CPU is
sampled from `/proc/1/stat` around each trial; client CPU uses `getrusage`.
RSS is sampled after each trial from `/proc/1/status`. Peak RSS is the process
high-water mark, including startup, warmup, and preceding workloads in that round;
it is not a per-request or per-workload allocation measurement.

Reproduce from the repository root, with Docker and Node available:

```sh
node research/http-throughput/run.mjs --smoke
node research/http-throughput/run.mjs --skip-build
node research/http-throughput/summarize.mjs
```

The first command builds LeanWeb and both Go binaries, runs `go vet` and Node
syntax checks, and packages Spring with Java compiler warnings as errors. The
second reuses those artifacts for the full measurement. Omit `--skip-build` to
build and measure in one invocation. Builds allow 120 seconds per command,
except Maven's 600-second dependency/build budget; load invocations allow 45
seconds. The runner records per-command elapsed time and cleans up only containers
carrying its unique ownership label. Do not run competing benchmarks or builds
during measurement.

## Evidence

### Executed measurements

Executed on 2026-10-31. The full run took 756.44 seconds and completed all 60
trials: **23,189,212 validated responses, zero response-validation or network
errors**. Startup probes and warmup traffic are excluded from those counts.
The initial smoke harness rejected Spring's valid compact Content-Type formatting;
the corrected harness parses media types and passed all four implementations.
No failed smoke measurements are included below.

Each value below summarizes three trials. CPU columns use whole-CPU equivalents,
not percentages. RSS is the median post-trial process resident memory.

| Workload | Clients | Server | Req/s median (range) | p50 ms | p95 ms | p99 ms | Server CPUs | RSS MiB | Client CPUs |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| health | 1 | LeanWeb | 7047 (6767–7089) | 0.145 | 0.172 | 0.192 | 0.90 | 40.0 | 0.31 |
| health | 1 | Node | 18388 (18233–18659) | 0.052 | 0.073 | 0.086 | 0.53 | 79.4 | 0.75 |
| health | 1 | Go | 17984 (16789–18146) | 0.054 | 0.073 | 0.098 | 0.74 | 14.4 | 0.70 |
| health | 1 | Spring | 12262 (12130–12287) | 0.080 | 0.090 | 0.108 | 0.56 | 280.6 | 0.52 |
| health | 8 | LeanWeb | 14268 (12819–14276) | 0.549 | 0.724 | 0.939 | 1.25 | 40.3 | 0.66 |
| health | 8 | Node | 56017 (54684–59562) | 0.136 | 0.198 | 0.289 | 0.98 | 79.4 | 2.77 |
| health | 8 | Go | 63224 (59218–64674) | 0.117 | 0.207 | 0.338 | 1.19 | 14.5 | 3.02 |
| health | 8 | Spring | 47064 (45578–47230) | 0.158 | 0.258 | 0.446 | 1.42 | 262.3 | 2.40 |
| health | 32 | LeanWeb | 13783 (13680–14343) | 2.216 | 2.755 | 3.940 | 1.27 | 38.8 | 0.71 |
| health | 32 | Node | 58874 (56363–61317) | 0.535 | 0.658 | 0.894 | 1.00 | 79.4 | 2.81 |
| health | 32 | Go | 102217 (99763–102433) | 0.278 | 0.601 | 1.041 | 1.77 | 14.6 | 4.33 |
| health | 32 | Spring | 73348 (68389–73894) | 0.385 | 0.824 | 1.315 | 1.69 | 256.5 | 3.18 |
| health | 128 | LeanWeb | 14315 (12885–14316) | 8.774 | 10.072 | 14.192 | 1.26 | 42.4 | 0.68 |
| health | 128 | Node | 58281 (55083–60592) | 2.181 | 2.405 | 2.654 | 1.00 | 79.4 | 2.79 |
| health | 128 | Go | 113431 (111587–114139) | 1.055 | 2.018 | 3.215 | 1.89 | 14.7 | 4.64 |
| health | 128 | Spring | 71483 (68785–73820) | 1.181 | 2.171 | 3.787 | 1.57 | 290.1 | 3.07 |
| echo | 32 | LeanWeb | 14089 (12539–14159) | 2.244 | 2.510 | 3.087 | 1.28 | 42.5 | 0.61 |
| echo | 32 | Node | 54181 (50833–55555) | 0.582 | 0.731 | 0.924 | 1.00 | 79.4 | 2.65 |
| echo | 32 | Go | 93265 (80989–94812) | 0.294 | 0.725 | 1.153 | 1.74 | 14.5 | 4.16 |
| echo | 32 | Spring | 66719 (59155–67822) | 0.427 | 0.902 | 1.503 | 1.65 | 290.2 | 2.96 |

The largest mean client CPU consumption in any trial was 4.66 of its six allowed
CPUs. This supplies headroom against the quota, not proof that client overhead
has no effect. Maximum observed process peak RSS across all trials was 61.1 MiB
for LeanWeb, 80.8 MiB for Node, 15.5 MiB for Go, and 298.0 MiB for Spring.

The p99 column does not describe the worst request. At concurrency 128, Spring
had individual requests lasting 1.06–2.03 seconds in all three trials, despite
the low-millisecond p99 values. Its elapsed trials therefore included up to
0.92 seconds of final drain time. The cause was not profiled. Per-trial maximum
latencies, durations, counts, and resource samples are retained in
[results.csv](results.csv).

### Checks and proof boundary

The benchmark Go programs passed `go vet`; their Go builds, Node syntax checks,
and the Spring build with `-Xlint:all -Werror` passed. The smoke run validated
both endpoints for every implementation before measurement. The unchanged LeanWeb
code also passed the full 69-job build, executable suites, 28 TCP tests, and
workflow checks. These measurements are runtime evidence only; no new kernel
proof or compiler/runtime guarantee is claimed by this experiment.

## Conclusion

For this workload at 32 clients, Node delivered **4.27×**, Go **7.42×**, and
Spring **5.32×** LeanWeb's median health throughput. LeanWeb's throughput stayed
around 13–14 thousand requests/second from 8 through 128 clients while latency
increased. The 1 KiB echo workload produced a similar LeanWeb rate.

LeanWeb used less resident memory than Node and Spring here, but more than Go.
These observations do not identify a bottleneck or isolate the cost of Lean,
proofs, the parser, worker scheduling, or the framework. Profiling is needed
before attributing the difference or recommending an optimization.

This is a baseline for a later before/after comparison. It cannot establish
whether the proposed dispatch state machine has acceptable overhead because
that implementation has not been built or measured.

## Uncertainty

Loopback and Docker Desktop are not deployment networks. Closed-loop latency is
not latency under an independent arrival rate. Servers do not have equivalent
features, and connection-close results do not measure keep-alive performance.
No measured baseline can establish the cost of an unimplemented refactor.

Node and Go are minimal standard-library handlers; LeanWeb includes its framework,
and Spring includes MVC/Tomcat. Request limits and admission policies differ;
in particular, LeanWeb backpressures acceptance above 32 active workers. All
measured bodies are small and valid, so this does not compare rejection paths.
Content-Type semantics and body bytes match, but header formatting and automatic
headers are not byte-identical. These are not feature-equivalent implementations.

No TLS, keep-alive, external services, persistence, large bodies, independent
arrival-rate load, long soak, cold-start timing, or host thermal isolation is
measured. RSS excludes kernel socket memory and the filesystem cache. CPU
snapshots include a small interval around the client measurement, and background
host activity remains uncontrolled. Three trials do not establish statistical
significance or a production capacity guarantee.

## Follow-ups

Repeat identical workloads after any dispatch implementation change before
attributing a performance difference to that change. Interleave baseline and
candidate runs; differences within the observed run-to-run spread need more
evidence, not a claimed speedup or slowdown.

## Artifacts

Experiment sources are [run.mjs](run.mjs), [client.go](client.go),
[server.go](server.go), [server.mjs](server.mjs), [the Maven project](spring/pom.xml),
and [summarize.mjs](summarize.mjs). Generated binaries, dependencies, raw trial
JSON, command logs, and generated summaries stay in `.work/`. The final report
and [normalized trial data](results.csv) are the durable evidence; no production
code changes are part of this assignment.
