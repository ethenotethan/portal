# Portal Architecture Observatory

This directory contains Portal's repository-native architecture model and the static application published through GitHub Pages.

## Authority model

- `model/model.json` is deterministic structural and behavioral evidence compiled from Swift source by `scripts/build_architecture.py`.
- `semantic/components.json` contains constrained, agent-synthesized component summaries with source evidence and model provenance.
- `specifications/` contains human-reviewed intended architecture.
- `site/` is the static GitHub Pages application over all three layers.

Generated observations do not override specifications or `docs/architecture-rules.md`.

## Two architecture planes

The observatory keeps two complementary planes separate:

- The **structural responsibility plane** assigns files and declarations to components, shows specified and observed component relationships, and layers bounded semantic component summaries over deterministic inventory.
- The **behavioral execution plane** reports only mechanically visible execution domains, task sites, stored transport/stream resources, and lifecycle operations. It is generated deterministically; no agent writes, completes, or interprets behavioral records.

Every behavioral item has a stable ID, an extraction `rule_id`, an evidence class, and repository-relative file/line provenance. The site links that evidence to the exact `#L<line>` source location.

## Deterministic behavioral extraction

`scripts/build_architecture.py` applies lexical rule families to Swift source after masking comments and string contents:

- `swift.execution.*` observes `@MainActor`, actor declarations, and named `DispatchQueue` fields.
- `swift.task.*` observes `Task` creation sites, stored task handles, and cancellation calls on recognized handles.
- `swift.resource.*` observes stored URL sessions, WebSocket tasks, stream continuations, locks, timers, Combine subjects, and source-visible SSE boundaries.
- `swift.lifecycle.*` observes mechanically associated factory, start, receive, send, close, publish, batch, scheduler-hop, lock, continuation, timer, subscription, and replay-cursor operations.

Connectivity pockets are **static owner/lifecycle clusters** grouped by source component and enclosing owner type. They are not runtime topology. Scenarios preserve source order among operations in one pocket; source order is explicitly not a claim about runtime order, causality, or timing.

### Evidence limits

Static lexical evidence does **not** establish:

- actual task or operation overlap;
- OS thread selection or scheduling;
- live socket, task, stream, or timer counts;
- dynamic aliases or interprocedural resource flows.

Regex recognition proves only that a supported source form is present at the cited location. Runtime telemetry would be a separate future evidence class with its own collection, provenance, retention, and authority rules; it must not be inferred from static records.

## Local development

```bash
make architecture
make architecture-check
make architecture-serve
```

The preview is served at <http://127.0.0.1:4173/>. Generated model and site-data files are checked in so pull requests show the exact architecture change that will be published.

## Continuous maintenance

`.github/workflows/architecture-maintenance.yml` is the manual fallback for architecture maintenance. It refreshes deterministic evidence with the compiler. When the model credential is configured, it gives each affected component to a separate bounded summarization call, validates the structured response, rebuilds deterministic outputs, and opens or updates `automation/architecture-portal` as a pull request.

The semantic maintenance agent is mechanically constrained to write only:

- `architecture/semantic/components.json`

Only `scripts/build_architecture.py` produces `architecture/model/model.json`, including `model.behavior`, and generated `architecture/site/data.js`. The agent cannot modify deterministic behavior, specifications, rules, workflows, or application source, and the workflow does not auto-merge.

### Repository configuration

Configure these in **Settings → Secrets and variables → Actions**:

| Kind | Name | Purpose |
|---|---|---|
| Secret | `ARCHITECTURE_OPENAI_API_KEY` | Credential for an OpenAI-compatible low-thinking model |
| Variable | `ARCHITECTURE_OPENAI_BASE_URL` | Optional API base, such as `https://openrouter.ai/api/v1` |
| Variable | `ARCHITECTURE_MODEL` | Optional model identifier; defaults to `gpt-4o-mini` |

Without the secret, deterministic graph maintenance still works and the workflow explicitly skips semantic summarization.

## Publishing

`.github/workflows/architecture-pages.yml` validates the checked-in model, tests the compiler, checks browser JavaScript, and deploys `architecture/site/` after a merge to `main`.

GitHub Pages must be configured once with **Source: GitHub Actions** in repository settings. The expected public URL is <https://ethenotethan.github.io/portal/>.

## Adding a component

1. Add a component and ordered path patterns to `architecture/config.json`.
2. Add explicit architectural relationships with source evidence when the relationship carries architectural meaning.
3. Run `make architecture`.
4. Run `make architecture-check`.
5. Review the graph and source inventory locally.

Patterns are first-match-wins. Feature-specific patterns must precede fallback components such as `local-services`, `domain-models`, and `shared-ui`.
