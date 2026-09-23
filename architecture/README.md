# Portal Architecture Observatory

This directory contains Portal's repository-native architecture model and the static application published through GitHub Pages.

## Authority model

- `model/model.json` is deterministic structural and behavioral evidence compiled from Swift source by `scripts/build_architecture.py`.
- `semantic/components.json` contains constrained, agent-synthesized component summaries with source evidence and model provenance.
- `specifications/` contains human-reviewed intended architecture, kept as documents in the repository; the site no longer renders them.
- `site/` is the static GitHub Pages application over all three layers. Its **System map** is the deterministic interplay graph described below; the earlier layered component map was retired in its favour, though the structural component model it drew from remains in `model.json` and drives the source inventory.

Generated observations do not override specifications or `docs/architecture-rules.md`.

## Two architecture planes

The observatory keeps two complementary planes separate:

- The **structural responsibility plane** assigns files and declarations to components, shows specified and observed component relationships, and layers bounded semantic component summaries over deterministic inventory.
- The **behavioral execution plane** reports only mechanically visible execution domains, task sites, stored transport/stream resources, and lifecycle operations. It is generated deterministically; no agent writes, completes, or interprets behavioral records.

Every behavioral item has a stable ID, an extraction `rule_id`, an evidence class, and repository-relative file/line provenance. The site links that evidence to the exact `#L<line>` source location.

## Deterministic behavioral extraction

`scripts/build_architecture.py` applies lexical rule families to Swift source after masking comments and string contents:

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

## Boundary plane: external systems and data stores

Two further deterministic node kinds sit beside the structural and behavioral planes:

- **External systems** are declared in `architecture/config.json` under `external_systems`. Each entry carries a human-written `description` (specified authority) and one or more `signatures`: regular expressions matched against comment- and string-masked Swift code, or, with `"scope": "strings"`, against string-literal contents only (for hostnames and endpoint paths). Every match is an observed item with file/line provenance and is attributed to the owning component; the compiler fails if a declared system matches nothing, so stale declarations cannot linger. An optional `component` links the system to an external graph node such as `device-services`.
- **Data stores** are recognised by type-name convention (`…Store`, `…Cache`, `…Inventory`, `…Ledger`). For each, the compiler observes the persistence mechanism (`file`, `defaults`, `keychain`) and any file or `isDirectory: true` folder literals inside the declaring type body, its same-file extensions, and same-file helper types whose name starts with the store name. A store with none of these is reported as `unobserved`, which means in-memory or delegated elsewhere, never "not persisted".

Both appear in the site as the **External systems** and **Data stores** views and as chips on the component inspector. In the **Interplay** graph the application itself is drawn as the outermost hull. Inside it the zones are the app's navigation pages, declared under `pages` in `architecture/config.json` with their root view types (main chat view, settings, sessions, cron, activity, skills, feed, learning, graphs, files, artifacts). The compiler walks same-file identifier references from each page's roots, never entering another page's roots or the shell, and assigns each type to the page that reaches it at the shortest distance. A tie, or a type no page reaches (a service the shell starts), is resolved by what pages declare they own: first the RPC `namespaces` the type invokes, then the `components` its file belongs to; each node records the rule that placed it in `page_resolution`. What still ties is `shared`. Anything reached from more than one page, or from none, sits in the shared core, except live objects that hold stored resources (the transport core with its pool, lock and socket): those are in-memory constructions and get their own hull inside the application boundary. External systems that an interplay node touches (same-file signature evidence) float around it, beside the nodes they link to, with a gateway boundary hanging beneath: every JSON-RPC and REST endpoint box carries a `served-by` edge into the gateway its transport reaches (drawn as a bus bar the endpoints sit on), on-device engines carry `runs-on` edges into their runtime, and recognised stores carry `persists-to` edges into the storage system that claims their observed mechanism. Every calling surface carries a `holds` edge to the one shared transport (and to the seam it is typed against), so concurrent access to the pool and socket is visible across pages. For each function on a transport or engine owner that acquires a lock, the extracted operations are assembled into a `section` node whose steps are listed in source order with the lock-guarded ones marked (for the gateway: lock → register → unlock → send in `call`, lock → unlock → resolve in `fulfillRequest`); source order is not a claim about runtime interleaving. The drawn flow is surface → client extension → core → namespace: a surface `calls` the `client` node for the `GatewayClient+<Feature>.swift` extension whose wrappers cover the namespace it invokes, every extension `routes-through` the one core, and the core `dispatches` every namespace it serves. The core itself is drawn as a box owning its pool, lock, socket, session and critical sections. The map is laid out radially: the in-memory constructions (the transport, engines with their model containers, pool owners, and every store with no observed persistence) sit in the centre with the shared core beneath them, and the pages ring them in declared order. Every recognised data store is a construction on the map, and a surface whose file names a store gets a `uses` edge to it; a store two pages tie for takes the single page whose surfaces reference it, else stays shared: a type that is already a surface is annotated with its persistence, any other store is its own `store` node placed by page, with in-memory stores no page owns joining the in-memory hull; and an owner of a continuation pool that does not conform to the seam (the file download manager) is admitted with the `pool` role. Triggers are the first hop: a SwiftUI action or lifecycle hook whose closure calls a method on a same-file property typed as a surface (receiver-qualified) is recorded with its view, method and the namespaces the method reaches, drawn as one page → surface edge per pair labelled with counts, and listed on the surface's inspector; `calls` edges carry which triggers fire them. The transport is drawn as one in-memory construction with two legs: the request leg is the transport core, collapsed by default and expanded on click to show its pool, lock, socket, session and critical sections; the push leg is the seam's `eventStream`, which the core feeds and every subscriber in its page taps, each tap recording how the binding schedules delivery (a `collect(.byTimeOrCount)` batching window or a `receive(on:)` scheduler, read from the operator chain after the binding). Pool owners outside the transport collapse and expand the same way. A client extension sits in the page that declares ownership of its namespace. System flows and the purpose of a relationship remain human-authored in `specifications/`; the boundary plane only records what the source mechanically shows.

Edges default to a quiet view: neutral aggregated trunks at rest (pages holding the core, the core dispatching the gateway, the event stream notifying pages, hulls crossing to each external system), with the full coloured detail and relation labels drawn only for the selected node's path. An **Edges** control switches to all edges.

## Interplay invariants (the anti-overfitting gate)

Every rendering above assumes a construction: one transport shared by every page, pool mutations under one lock with resumes and socket writes outside it, every namespace dispatched by the core, every page owning something. Those assumptions are written down in `architecture/interplay/invariants.json`, each with a `why`, and `scripts/build_architecture.py` checks them against the extracted model on every build. A violation fails `make architecture` and `--check` with the invariant id, the offending source site, and the declared reason. Changing the construction is allowed; it requires changing the declaration in the same change, so the graph can never quietly describe code that no longer has that shape. Results are published under `interplay.invariants`, and the System map's **Invariants** dropdown lists each one with its status; selecting one opens a description of what it pins and why.

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
