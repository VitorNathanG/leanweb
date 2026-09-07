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
| `lean-tcp-cancellation` | superseded | root / workflow-bootstrap | Is the 4.24 pending-receive cancellation path safe to use for deadlines? Source inspection only. | `research/lean-tcp-cancellation/` | Lean v4.24.0; exact commit in report | Historical payload/wrapper mismatch; no crash reproduction. Replaced for the current pin by the 4.33.1 qualification below. | [Source assessment](../lean-tcp-cancellation/README.md) |
| `lean-4.33-receive-deadline` | complete | compatibility-researcher / receive-deadline-qualification; root integration | Qualify pending receive cancellation, timer cleanup, and completion races for the bounded server slice; exclude write/handler deadlines. | `research/lean-4.33-receive-deadline/` | Lean v4.33.1, `819816b2e0a3bf405af45ae5c7af2491d8f5bee6` | Three compiled probe runs passed; actual-server deadline/backpressure and FD regressions passed. Listener-error cleanup and general memory/resource safety remain unqualified. | [Qualification](../lean-4.33-receive-deadline/README.md) |

## Assignment Rules

Record stable ID, status, owner/task identifier, question/scope, unique writable
directory, reference pin, bounded conclusion/uncertainty, and evidence link.
The index directory is reserved for curation, not probes. Never concurrently
assign one directory to multiple researchers; stop unexpected overlap.

The root performs mechanical updates. Use one curator at a time for substantive
synthesis, contradictions, stale evidence, or deduplication. Preserve distinct
evidence classes and conditions, and link replacements without rewriting reports.
