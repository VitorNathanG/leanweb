---
name: lean-runtime-research
description: Investigates Lean and libuv APIs, cancellation, HTTP boundaries, and resource behavior using pinned source evidence and bounded reproducible probes.
---

# Lean Runtime Research

Use for transport/runtime questions or experimental evidence, not ordinary
mechanical edits. Read [AGENTS.md](../../../AGENTS.md),
[PRODUCT.md](../../../PRODUCT.md), and the [research index](../../../research/index/README.md).
Search existing evidence before proposing another experiment.

## Bound The Assignment

The root specifies a concrete question and either explicit read-only review or
exactly one registered writable directory under `research/`, excluding the index.
Read-only assignments produce no files. Experimental probes, reports, and their
ignored `.work/` artifacts stay within the assigned directory.

Pin the Lean revision, upstream API/source version, OS/architecture, and relevant
tool versions. Use public upstream URLs, not references to local repositories.
Respect licenses and preserve attribution when incorporating upstream source.

## Probe Deliberately

- Start with source contracts and implementation ownership/lifetime paths. State
  a falsifiable question before writing a probe.
- Prefer the smallest Lean executable and dependency-free Node client that can
  exercise the boundary. Do not add production patches during a research assignment.
- Use only owned disposable processes and loopback sockets. Set input, resource,
  and wall-time limits; plan ownership-checked cleanup and diagnostic retention.
- Never assume dropping a task/promise cancels the underlying operation. Inspect
  pending reads/writes, callback ownership, cancellation resolution, and races.
- Compare expected and observed behavior. Exercise error and boundary paths,
  including completion versus cancellation, rather than only a happy-path exchange.
- Repeat timing-sensitive experiments and report ranges with the repetitions,
  configuration, and elapsed time. A single run is not a resource guarantee.
- Keep useful normalized text. Do not commit binaries, caches, user data,
  credentials, or machine-specific output. Record harness failures separately.

## Report Format

Each report has a `README.md` with these sections:

- `Question`: decision being informed, scope, and explicit exclusions.
- `References`: exact revisions/versions, public source URLs, and relevant environment.
- `Procedure`: reproducible commands or source-inspection steps, limits, repetitions.
- `Evidence`: separately label source contracts, implementation observations,
  executed tests, kernel proofs, and inference. Say explicitly when a class is absent.
- `Conclusion`: bounded answer and what evidence supports it.
- `Uncertainty`: missing cases, environmental limitations, and revalidation triggers.
- `Follow-ups`: candidate regression assertions or proof obligations, not a second roadmap.
- `Artifacts`: report/probe paths, generated-output location if used, and useful reflection candidates.

The index owns assignment/status metadata; the report owns detailed results.
Ask the root to mark it complete only after reviewing the evidence and artifacts.
Source-only completion is permitted but must never imply an executed reproduction.
