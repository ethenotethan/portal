# Portal Software Factories Context

Two bounded software factories share one operational surface. GitHub Issues hold Product Factory intent; repository metrics seed the Verifier Ratchet. Their policy profiles and queues remain independent while one persistent `portal-software-factories` model artifact shows both boards.

## Language

**Verifier Ratchet**: Repository-driven workflow that finds bounded, measurable improvements without a GitHub Issue.
_Avoid_: product factory, issue factory

**Product Factory**: Demand-driven workflow beginning with a GitHub Issue and ending only after post-merge validation on accepted `main`.
_Avoid_: ratchet

**Issue Record**: GitHub-owned product intent, priority, acceptance criteria, discussion, and open/closed status.

**Case**: Campaign-owned operational mirror of one executable GitHub Issue.
_Avoid_: duplicate issue

**Mirror**: Idempotent translation between GitHub and the Case ledger; it never transfers source authority.

**Control Label**: An orthogonal GitHub label requesting or denoting a validated transition.

**Accepted Intent**: Digest-bound Issue body, acceptance criteria, parent relationship, and controlling labels captured on entry to Ready.

**Interactive Validation**: Independent reproduction of the exact candidate or accepted revision in the real Portal application through `cua-driver`.
_Avoid_: screenshot review, unit-test-only validation

**Substantive Attempt**: An implementation/review cycle rejected for product or code behavior. Infrastructure failures are not substantive attempts.

## Relationships

- One executable **Issue Record** produces exactly one **Case** and at most one active product PR.
- A complex parent Issue may produce at most five active child Issues, one level deep.
- A **Case** produces separate-generation triage, implementation, review, validation, and post-merge-validation dispatches.
- The **Product Factory** and **Verifier Ratchet** share infrastructure but use separate capacity, labels, merge-policy profiles, and scorecards.
- The shared model artifact contains `product_cases` and `ratchet_work` entity sets with separate Kanban views; it is a projection, not an authority source.

## Resolved terminology ambiguities

- `factory:ready` is the explicit admission label; `state:ready` denotes the validated lifecycle state after admission predicates pass.
- GitHub owns issue closure; the factory bot may perform the close only after post-merge evidence satisfies policy.
- Labels request transitions, while the Case ledger records whether the transition was accepted or rejected.

## Implementation gates

- Observe: read and propose only.
- Plan: labels, comments, and bounded sub-issues; no code mutation.
- Produce: PR production plus independent review/validation; human merge.
- Close loop: policy-gated merge and evidence-backed Issue closure.

## Shared operational surface

- Artifact: `portal-software-factories` (`model`).
- Product board: all mirrored Issues, including a terminal `closed` lane; dispatch remains gated by `factory:ready`.
- Ratchet board: offered verifier candidates plus active ratchet/escalation PRs from the existing merge queue.
- Observe publisher: a fail-closed, read-only five-minute job. It may update the local Case ledger and replace the projection, but applies zero GitHub actions and dispatches zero workers.
