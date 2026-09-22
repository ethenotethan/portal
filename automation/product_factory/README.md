# Portal Product Factory

This directory contains the versioned, fail-closed control plane for Portal's
Issue-driven autonomous workflow. It is separate from the verifier-ratchet lane.

## Current activation

`policy.v1.json` is intentionally set to **Observe**. The reconciler reads live
GitHub Issues, mirrors them into a local SQLite Case ledger, validates control
labels, binds accepted-intent digests, and emits proposed actions. It cannot
mutate GitHub, dispatch workers, merge PRs, or close Issues in this stage.

```bash
make product-factory-test
python3 -m automation.product_factory.cli reconcile \
  --db /tmp/portal-product-factory.db
python3 -m automation.product_factory.cli project \
  --db /tmp/portal-product-factory.db
python3 -m automation.product_factory.cli topology
```

The `project` command emits a complete Portal `model` artifact specification. It
uses the existing model/Kanban/table renderers, so v1 requires no new Swift UI.

## Files

- `policy.v1.json` — rollout authority, capacity, attempts, labels, and split merge profiles.
- `policy.schema.json` — contract schema.
- `labels.v1.json` — complete GitHub label manifest with descriptions and colors.
- `policy.py` — exclusive dimensions, admission, actor authority, transitions, and intent digest.
- `github.py` — read-only paginated GitHub Issue source.
- `reconciler.py` — idempotent Issue → Case mirror and proposed transition repair.
- `planner.py` — P0–P3 deterministic WIP planner with a reserved regression slot.
- `dispatcher.py` — idempotent, separate-generation Kanban task adapter.
- `merge_policy.py` — independent review, exact-SHA CI/CUA, ratchet, and closure gates.
- `attempts.py` — two-correction substantive retry budget; transient failures are free.
- `projection.py` — existing Portal model artifact projection.
- `topology.v1.json` — canonical cron dataflow and explicit authority relationships.
- `topology.py` — validates that topology, derives model edges, and emits `cron.update` payloads.
- `cli.py` — observe-stage reconcile and projection commands.

The `topology` command is read-only. Its `cron_updates` array uses the supported
cron contract fields (`inputs`, `outputs`, `side_effects`, and `source_files`)
and can be applied by the deployment owner. The model graph is built from those
same declarations with the `cron.graph` wire semantics: ordinary `inputs`
become `reads`, `cron-output:<id>` inputs become direct job-to-job `feeds`,
`outputs` become `writes`, and each side effect uses its scheme as the edge
type. Scheduler and human-governance edges are separately marked as explicit
relationships, so they cannot be mistaken for data movement or delivery.

The synchronizer and merge queue are repository-owned scripts under `scripts/`.
Their topology entries include `script`, so applying the emitted updates moves
the scheduled jobs onto the reviewed implementations instead of retaining a
parallel copy under `~/.hermes/scripts`.

## Event ingestion

There is no specialized durable GitHub gateway in the installed Hermes tree.
The shipped generic webhook adapter deduplicates delivery IDs in memory, which
is useful for low latency but is not restart-durable. Therefore reconciliation
is the completeness mechanism. A gateway route may feed a normalized Issue
snapshot to `reconcile --input-json`; the periodic full GitHub read repairs any
missed event through the same fingerprinted idempotent core.

Do not create a second webhook service. The existing durable polling pattern is
`~/.hermes/scripts/darkbloom-pr-poller.py`, whose pending/ack ledger survives
failed agent runs. Product Factory activation should call this repository's
reconciler from that single ingestion path after merge.

## Campaign dispatch

The planner emits at most two ordinary implementation-through-validation Cases
plus one reserved regression Case. `dispatcher.py` uses Kanban's public
`create_task()` path with an idempotency key and a task-owned worktree. A
production deployment should prefer the authenticated Kanban dashboard REST API
(`/api/plugins/kanban`) when process/version boundaries differ; the direct
Python adapter is for the same-host, version-pinned install.

Never write directly to the Kanban SQLite tables. Lifecycle transitions perform
cleanup, dependency promotion, event emission, and hooks that direct SQL would
bypass.

## Rollout promotion

Promotion is a reviewed contract change, not a runtime flag flip:

1. **Observe** — current stage; read, mirror, validate, propose.
2. **Plan** — permit label/comment/sub-issue mutation only.
3. **Produce** — permit bounded agent dispatch and PR creation; human merge.
4. **Close loop** — permit policy-gated merge and evidence-backed Issue closure.

Before each promotion, add tests for the newly granted authority, update the
policy schema/contract together, run an observe reconciliation against live
GitHub, and independently review the immutable candidate revision.
