---
name: lean-proof-development
description: Develops and reviews LeanWeb router, decoder, middleware, and controller contracts while preserving executable connections and auditing proof assumptions.
---

# Lean Proof Development

Use for theorem work, typed input validation, policy/controller composition, or
changes to definitions mentioned by the [proof boundary](../../../docs/architecture.md).
Read [AGENTS.md](../../../AGENTS.md) and [PRODUCT.md](../../../PRODUCT.md) first.
This skill refines the shared workflow; it does not grant edit or commit permission.

## Establish The Claim

1. Identify the user-visible behavior and the executable definition serving it.
2. Write down input domain, source relation, precondition, output relation, effects,
   and explicit failure behavior. Consult existing tests and rationale in history.
3. Identify what the existing theorem proves and what lies outside it. Preserve
   supported behavior; obtain agreement for an intended contract change.

For decoders, retain a relation between the actual request fields and decoded
values, not just a range check. For controllers, connect the decoder's proof to
the accepted input and the response actually returned. For policies, distinguish
selecting a rejection action from proving that an arbitrary action has no effects.

## Implement And Prove

- Prefer total, small definitions and standard kernel-checked tactics. Start
  with `rfl`, `simp`, case analysis, induction, and arithmetic lemmas as appropriate.
- Change the implementation and its proof together. Do not copy a separate model
  and claim it verifies an IO path without showing their connection.
- Check positive reachability as well as rejection: a soundness theorem alone can
  be satisfied by a decoder that always fails. Add success/boundary regressions.
- Keep ordinary runtime assertions and IO/TCP tests. Proofs cannot replace checks
  of the FFI, byte framing, external services, cancellation, or runtime execution.
- Do not introduce `sorry`, `admit`, custom axioms, `native_decide`, unsafe proof
  shortcuts, or warning suppression. Do not erase constraints to simplify a proof.

## Check The Boundary

Build affected modules first, then use the complete checks in
[Development](../../../docs/development.md). Inspect `#print axioms` for changed
important declarations and compare with their previous dependencies where available.
Standard Lean axioms are not automatically defects; report unexpected additions
and explain the trusted basis rather than relying only on a textual token scan.

Before integration, review:

- Exact theorem quantifiers, non-vacuous hypotheses, and success cases.
- Missing, duplicate, invalid, oversized, and boundary inputs.
- Whether the router/application selects the proved controller and policy.
- Whether rejected input reaches any downstream effect contrary to the contract.
- Compiler/runtime/FFI assumptions and any unsupported protocol behavior.
- Tests that would fail if the intended guarantee were removed.

Request a read-only proof review for substantial contract changes. Supply actual
axiom/build/test output; the reviewer does not run checks. Report separately what
was implemented, kernel-checked, runtime-tested, and left uncertain.
