# LeanWeb Working Agreement

## Principles

- Deliver the smallest coherent, independently verifiable increment. Prefer a
  usable end-to-end behavior with its essential correctness checks over an
  expanding sequence of infrastructure or research projects.
- Inspect the code and existing evidence before choosing a design. Prefer the
  smallest correct change; preserve unrelated work and avoid speculative compatibility.
- Give each rule, decision, result, and status one authoritative home. Link to
  that home rather than maintaining competing summaries.
- Distinguish proposed, implemented, kernel-checked, and runtime-tested behavior.
  Never describe the entire server as formally verified because its core has proofs.
- Run narrow checks before broad checks. Parallelize independent work, use
  explicit timeout budgets, and record elapsed time for expensive checks and
  performance claims. Do not repeatedly interrupt a known cold build.

## Required Context

Read this file and [PRODUCT.md](PRODUCT.md) before working. Consult the remaining
context relevant to the assignment, not every document indiscriminately.

| Location | Authority |
| --- | --- |
| [PRODUCT.md](PRODUCT.md) | Product goal, current scope, acceptance gates, non-goals |
| [ROADMAP.md](ROADMAP.md) | Future work in execution order |
| [README.md](README.md) | User-facing API, HTTP subset, and quick start |
| [Architecture](docs/architecture.md) | Boundaries, decisions, and evidence map |
| [Development](docs/development.md) | Tools, verification, and agent operation |
| [Research index](research/index/README.md) | Assignments and evidence locations |
| [Memory](.agents/MEMORY.md) | Durable non-obvious lessons |
| [Suggestions](.agents/SUGGESTIONS.md) | Workflow improvements, not product backlog |

Read relevant Git history for rationale and rejected alternatives. The current
worktree defines present behavior when older commits or research differ.
Keep this repository self-contained: do not add paths or references to other
local repositories, machine-specific toolchain locations, or user-global settings.

## Proof Integrity

- Preserve the connection between the theorem and the executable definition
  actually used by the application. Review both when either changes.
- Do not add `sorry`, `admit`, custom axioms, `native_decide`, or unsafe proof
  shortcuts. Do not disable warning-as-error checks to make a build pass.
- Do not silently weaken a postcondition, strengthen a precondition, erase a
  source relation, or replace a supported behavior with rejection. Explain any
  intended contract change and obtain agreement before changing its meaning.
- For important proof changes, inspect `#print axioms` output and explain any
  change in dependencies. Standard Lean axioms are not automatically defects;
  undocumented additions to the trusted basis are.
- Kernel proofs, executable unit tests, TCP tests, upstream source inspection,
  and performance measurements are different evidence classes. None replaces
  the others at a boundary it does not cover.
- Keep decoding, policy, and controller contracts explicit. Unsupported input
  must fail deliberately, before downstream effects where the contract requires it.
- Use the [Lean proof skill](.opencode/skills/lean-proof-development/SKILL.md)
  for decoder, router, middleware, or controller contract changes.

## Roles And Ownership

- The root agent owns integration and edits production code, tests, build/CI,
  general documentation, configuration, planning files, and `.agents/`.
- Delegate only substantial, separable work. Subagents return evidence or
  findings, not production patches or commits.
- A researcher assignment is either explicitly read-only, or names exactly one
  unique writable directory under `research/`, excluding `research/index/`.
  Generated artifacts must also stay in that assignment's ignored `.work/`.
- Register an experimental assignment in the research index before delegation:
  question, owner/task identifier, scope, directory, reference pin, and status.
  Never assign the same directory concurrently. Read-only reviews need no report
  directory; record findings in the integrating task or commit as appropriate.
- The curator may edit only `research/index/`; use one curator at a time and only
  for substantive synthesis. The root handles mechanical catalog updates.
- The proof reviewer is read-only. It checks claims, assumptions, execution
  paths, and missing tests, and must not claim to have run checks it cannot run.
- The root reviews the before/after changed paths and all returned artifacts.
  Stop conflicting assignments. Prompt and tool permissions are not a sandbox;
  use isolation when actual containment is required.

## Research And Experiments

- Check the research index before starting. Prefer pinned upstream Lean sources,
  API documentation, and protocol specifications; record exact revisions and
  relevant environment details. Respect upstream licenses and attribution.
- Follow the [runtime research skill](.opencode/skills/lean-runtime-research/SKILL.md).
  Reports must separate source contracts, implementation observations, executed
  results, kernel proofs, and inference, with explicit remaining uncertainty.
- Use small reproducible probes. Record commands, expected/actual outcomes,
  repetitions for timing-sensitive behavior, and proof or regression candidates.
- Test only owned disposable processes and loopback sockets. Bound resources
  and execution; never kill unrelated processes, connect to user services, or
  remove unowned data. Retain useful diagnostics without committing binaries,
  credentials, caches, or machine-specific output.
- Do not infer cancellation safety, HTTP conformance, effect safety, or resource
  bounds from a passing pure proof or a single successful socket exchange.

## Development Cycle

1. Identify the user-visible increment, existing contract, and relevant roadmap item.
2. Inspect implementation and evidence; delegate bounded research only if needed.
3. Implement the smallest complete slice, preserving explicit unsupported behavior.
4. Add or update proofs, executable tests, and boundary tests for the actual claim.
5. Run focused checks, then the applicable full verification in Development.
6. Review the diff and proof boundary; update authoritative docs and remove
   completed roadmap work. Reflect before committing or reporting completion.

Keep production code in Lean and the existing Node test harness dependency-free
unless a concrete requirement justifies a change. Manual edits use `apply_patch`.
Avoid unrelated refactors and new abstraction layers without a use case.

## Roadmap And Reflection

- Keep only future work in `ROADMAP.md`, in an unnumbered execution-ordered list.
  Each item should name a deliverable and its verification, not just an activity.
- Remove completed work and insert discovered requirements where they belong.
  Keep independent reprioritization separate from implementation when practical;
  a coherent initial setup does not need an administrative follow-up commit.
- After each coherent unit, compare intent, outcome, uncertainty, and possible
  improvements. Review Memory and Suggestions; add only useful new information.
- Prune stale, duplicated, superseded, or implemented entries. Do not store
  secrets, local paths, policy duplicates, indexed research, a commit log, or a
  second roadmap there. Subagents return candidates; only root updates them.

## Commits And Reporting

- Commit only when explicitly authorized. A request to commit one task is not
  standing authorization for future commits. Only the root agent commits.
- Inspect `git status`, unstaged and staged diffs, and recent history first.
  Stage only intended files, inspect new files for secrets and generated output,
  and run both unstaged and staged whitespace checks.
- Use a concise imperative subject and plain prose explaining the change, why,
  relevant alternatives, verification, and limitations. No mandatory prefix or
  Markdown formatting in commit messages.
- Do not bypass hooks, amend, rewrite history, change Git identity, add remotes,
  or push without the corresponding explicit authorization.
- Report changes, checks actually run, remaining limitations, and the commit
  identifier when applicable. Include a concise next step when useful.
