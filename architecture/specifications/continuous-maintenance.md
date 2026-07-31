# Continuous maintenance

Portal maintains architecture as versioned repository state rather than as an external documentation database.

## Incremental process

1. A source change is mapped to affected architecture components.
2. Deterministic discovery refreshes file, declaration, and dependency evidence.
3. A constrained documentation agent receives only the affected components, changed files, existing semantic records, and output schema.
4. The agent proposes structured component summaries with repository-relative evidence.
5. Validation rejects unsupported component IDs, missing source files, and malformed records.
6. The bounded Hermes cron worker prepares one qualified documentation branch in an isolated worktree. Push and pull-request creation remain behind the configured operator policy.
7. Once publication is authorized, automation opens or updates one documentation pull request.
8. Human review and merge make the result canonical and publish it through GitHub Pages.

## Agent scope

The maintenance agent may update synthesized component summaries. It does not edit architectural specifications, CI rules, ADRs, workflow permissions, or source code. It cannot merge its own pull request.

If evidence is insufficient, the agent records an open question rather than inventing a conclusion.

## Reconciliation

Incremental updates are supplemented by a scheduled full deterministic rebuild. The Hermes cron worker owns the normal schedule; the repository workflow is a manually dispatched fallback rather than a competing scheduler. The rebuild detects removed files, changed component membership, stale evidence, and graph drift. Semantic summaries are revalidated against the current source commit before publication.

## Reproducibility

The architecture model and site are generated with Python's standard library. Generated files contain stable, repository-relative data and do not include wall-clock timestamps. Re-running the compiler at the same source revision must produce the same result.
