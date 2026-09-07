# Development

## Prerequisites

- Install [elan](https://github.com/leanprover/elan#installation), which resolves
  the version in [lean-toolchain](../lean-toolchain). Do not hard-code a developer's
  temporary installation path into scripts or documentation.
- Use Node.js 22 or newer for the dependency-free test and workflow scripts.
- Linux is the currently tested runtime environment. The compiler/runtime and
  internal TCP API are part of the toolchain-upgrade qualification boundary.
- No npm install is needed for repository tests. Lake dependencies are recorded
  in [lake-manifest.json](../lake-manifest.json), currently with no external packages.

## Verification

Run from the repository root. The [CI workflow](../.github/workflows/ci.yml) runs
the same build and executable checks.

```sh
lake build
lake exe leanweb_tests
node --test tests/http.test.mjs
node scripts/check-workflow.mjs
git diff --check
git diff --cached --check
```

`lake build` includes the library, server, test entrypoint, and proof-bearing
example; `lake exe leanweb_tests` actually executes tests. A successful build
alone is not a successful test run. The socket suite starts its own built server
on an available loopback port and stops that owned child when finished. It does
not require a manually running server or contact an external service.

Use explicit budgets: typically up to 120 seconds for a build or Lean test command
and 40 seconds for the socket suite; allow toolchain downloads/cold builds a
justified larger budget. A test timeout is not a server deadline. Preserve useful
failure output and investigate rather than disabling an assertion or timeout.

Focused checks shorten feedback:

```sh
lake build LeanWeb.Router LeanWeb.Decoding LeanWeb.Example
lake build LeanWeb.WireTests LeanWeb.DecodingTests
```

For important proof changes, use `lake env lean` on an owned ignored scratch
module under `.work/` containing imports and commands such as:

```lean
import LeanWeb.Example
#print axioms LeanWeb.Router.lookup_sound
#print axioms LeanWeb.Decoder.handle_error
#print axioms LeanWeb.Example.divisionController
```

Inspect the actual dependencies and explain changes. Text searches for proof
shortcuts are useful review aids, not a transitive axiom audit. The workflow
checker validates repository-relative documentation links, required guidance,
agent/skill metadata, and evidence-report structure; it does not certify proofs,
external URLs, Markdown fragments, or the security of agent permissions.

## Agent Operation

The normal OpenCode build agent remains the root integrator. Project definitions
are auto-discovered; no provider, model, MCP server, external directory, or user
credential configuration is supplied by this repository.

| Agent | Assignment | Writable boundary |
| --- | --- | --- |
| `compatibility-researcher` | Pinned Lean/API/protocol investigation or a reproducible probe | One explicitly assigned research directory; none in read-only mode |
| `research-curator` | Reconcile, index, and qualify existing evidence | `research/index/` only |
| `proof-reviewer` | Review proof assumptions, actual execution paths, regressions, and claims | None; shell execution is disabled |

| Skill | Trigger |
| --- | --- |
| `lean-proof-development` | Router, decoder, policy, controller, theorem, or trust-boundary changes |
| `lean-runtime-research` | Lean/libuv API investigation, transport experiments, or evidence reports |

Inspect discovery from this directory:

```sh
opencode agent list
opencode debug agent compatibility-researcher
opencode debug agent research-curator
opencode debug agent proof-reviewer
opencode debug skill
```

Ask the root agent to delegate with the named role; do not assume a subagent is a
primary interactive agent. Quit and restart OpenCode after changing agent or skill
definitions: running sessions retain already-loaded configuration.

Every delegation must include the question, read-only versus experimental mode,
allowed directory if any, reference pins, existing evidence, acceptance checks,
timeout/resource limits, and required return format. Capture the before/after
worktree paths, include newly created files in the audit, and inspect returned
artifacts before integrating. Tool permissions cannot constrain an approved
shell command to one directory; these roles are not isolation boundaries.

Experimental work is registered in the [research index](../research/index/README.md).
Keep generated outputs in the assignment's ignored `.work/` and provide a small
report/probe suitable for version control. Read-only reviewers receive the diff,
relevant source and contract, checks run, and known limitations; they return
findings with file/line references, assumptions, and coverage gaps.

## Change Hygiene

Follow [AGENTS.md](../AGENTS.md) for ownership, proof integrity, and commit policy.
Keep runtime/build artifacts ignored, do not add local repository references,
and never commit credentials. Preserve the repository-local Git identity unless
the user explicitly requests a change. Stage explicit intended paths and inspect
both staged and unstaged changes before an authorized commit.
