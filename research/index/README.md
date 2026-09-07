# Research Index

Canonical assignment and evidence catalog. Check before starting research; the
root registers experiments before delegation. Reports own detailed evidence,
[PRODUCT.md](../../PRODUCT.md) owns current scope, and [ROADMAP.md](../../ROADMAP.md)
owns future delivery order. Read-only reviews need no report or directory.

## Status Definitions

- `planned`: scoped question, not currently assigned for execution.
- `active`: assigned to the recorded owner/task; its directory is reserved.
- `complete`: reviewed evidence answers the bounded question. Source-only work
  can be complete without being runtime-tested or kernel-proved.
- `stale`: a reference or contract changed and the conclusion needs revalidation.
- `superseded`: replaced by stronger evidence, linked explicitly in the entry.

## Catalog

| ID | Status | Owner/task | Question and scope | Directory | Reference | Conclusion and uncertainty | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lean-tcp-cancellation` | complete | root / workflow-bootstrap | Is the pinned pending-receive cancellation path safe to use for deadlines? Source inspection only. | `research/lean-tcp-cancellation/` | Lean v4.24.0; exact commit in report | Cancellation decrements a raw payload pointer rather than its Lean wrapper. Do not use it for deadlines without qualification. No reproducible crash probe or fixed-version qualification in this report. | [Source assessment](../lean-tcp-cancellation/README.md) |

## Assignment Rules

Record stable ID, status, owner/task identifier, question/scope, unique writable
directory, reference pin, bounded conclusion/uncertainty, and evidence link.
The index directory is reserved for curation, not probes. Never concurrently
assign one directory to multiple researchers; stop unexpected overlap.

The root performs mechanical updates. Use one curator at a time for substantive
synthesis, contradictions, stale evidence, or deduplication. Preserve distinct
evidence classes and conditions, and link replacements without rewriting reports.
