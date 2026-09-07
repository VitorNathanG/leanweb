# Memory

Durable, non-obvious lessons only. Shared policy belongs in [AGENTS.md](../AGENTS.md),
product work in [ROADMAP.md](../ROADMAP.md), and research evidence in its catalog.
Prune an entry when it becomes stale, duplicated, or obvious from its authority.

- On the pinned Lean toolchain, deriving both `BEq` and `DecidableEq` does not
  automatically give the derived `BEq` a `LawfulBEq` proof. List membership
  decidability can then fail during `by decide` route registration. The
  [route key](../LeanWeb/Router.lean) derives `DecidableEq` without a separate
  `BEq`; preserve a lawful equality path rather than bypassing proof checking.
