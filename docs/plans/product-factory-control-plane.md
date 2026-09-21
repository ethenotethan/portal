# Product Factory Control Plane — implementation plan

## Goal

Add a second, issue-driven autonomous workflow alongside the existing verifier-ratchet fleet. GitHub owns intent, priority, acceptance criteria, labels, and closure. A local durable campaign ledger owns execution state, attempts, evidence, and dispatch identities.

## Authority boundaries

- Default rollout stage is `observe`: read GitHub and compute transitions, with no GitHub mutation, Kanban dispatch, push, merge, or issue closure.
- Control labels are orthogonal and validated before a transition is accepted.
- Human-only labels (`factory:design-approved`) are never minted by automation.
- Product and ratchet merge policy profiles remain separate.
- No worker may push directly to `main`.

## Vertical slices

1. **Contract and state machine**
   - Versioned policy JSON and JSON Schema.
   - Exclusive label dimensions and transition validation.
   - Intent digest and material-edit invalidation.
   - Priority/WIP calculation and one-level decomposition constraints.

2. **Durable reconciliation**
   - Fetch all open and closed GitHub Issues and relevant PRs.
   - Upsert every Issue into a SQLite Case ledger.
   - Produce deterministic proposed actions in observe mode.
   - Use the reconciliation poller as the durable completeness mechanism; any future webhook path must feed the same idempotent core and is only an acceleration layer.

3. **Campaign dispatch**
   - Create idempotent, separate-generation Kanban tasks for triage, implementation, review, interactive validation, and post-merge validation.
   - Two ordinary implementation-through-validation slots plus one reserved regression slot.
   - Two substantive corrective attempts; transient failures excluded.

4. **Acceptance policy**
   - Shared merge-policy evaluator with `ratchet` and `product` profiles.
   - Product profile requires linked executable Issue, accepted-intent digest, independent review, required CUA evidence, and green CI.
   - Post-merge validation closes the Issue only after accepted `main` passes.

5. **Portal projection**
   - Use one persistent `portal-software-factories` model artifact as the control center.
   - Render separate Product Factory and Ratchet Improvement Factory Kanban views from separate entity sets.
   - Reuse the existing artifact/model/Kanban renderer; no new Swift UI is required.

## Verification

- Strict RED→GREEN unittest slices for each behavior.
- Reconcile fixtures prove idempotence, conflict rejection, intent invalidation, and WIP bounds.
- Dry-run against live GitHub reads without mutation.
- Canonical repository checks after final integration.
- Independent specification review, then code-quality review, against an immutable snapshot.

## Non-goals for the first activation

- No live label creation or mutation.
- No automatic issue decomposition on GitHub.
- No PR creation, merge, or issue closure.
- No gateway restart.
- Observe-stage cron activation is allowed because it has zero GitHub mutation, dispatch, push, merge, or closure authority.

Those authorities are unlocked only by the staged rollout: Observe → Plan → Produce → Close loop.
