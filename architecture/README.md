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

A store's body also names what it writes: file literals (`artifacts.json`), directories passed with `isDirectory: true` (`portal/sessions`), and UserDefaults keys handed to `forKey:` directly or through a `let` constant the store resolves. Each becomes an **artifact** node drawn inside the storage system that owns its mechanism, so a store `persists-to` the file it writes and the file is `stored-in` its system; a mechanism with no named artifact links the store to the system itself. When one directory literal accompanies file literals it is their folder (`portal/artifacts.json`); two nested directory literals with no file read the same way (`portal/wiki-graph-cache`). External systems are boxed by category through `external_groups` in `architecture/config.json`: **Platform storage** (Application Support files, UserDefaults, Keychain) and **On-device inference** (the MLX runtime and the speech engines) are each drawn as one boundary beside the application, the way the gateway is drawn beneath it. A group names categories, never systems, so a new system of a boxed category lands in the box without a config edit; a group that boxes nothing fails the build. The semantic flows that walked a store to its system now walk it to the artifact and on into the system.

Neither has a page of its own: the site draws both on the **System map** (external systems as boundary hulls, stores as storage containers with their artifact nodes) and lists them as chips on the component inspector. In the **Interplay** graph the application itself is drawn as the outermost hull. Inside it the zones are the app's navigation pages, declared under `pages` in `architecture/config.json` with their root view types (main chat view, settings, sessions, cron, activity, skills, feed, learning, graphs, files, artifacts). The compiler walks same-file identifier references from each page's roots, never entering another page's roots or the shell, and assigns each type to the page that reaches it at the shortest distance. A tie, or a type no page reaches (a service the shell starts), is resolved by what pages declare they own: first the RPC `namespaces` the type invokes, then the `components` its file belongs to; each node records the rule that placed it in `page_resolution`. What still ties is `shared`. Anything reached from more than one page, or from none, sits in the shared core, except live objects that hold stored resources (the transport core with its pool, lock and socket): those are in-memory constructions and get their own hull inside the application boundary. External systems that an interplay node touches (same-file signature evidence) float around it, beside the nodes they link to, with a gateway boundary hanging beneath: every JSON-RPC and REST endpoint box carries a `served-by` edge into the gateway its transport reaches (drawn as a bus bar the endpoints sit on), on-device engines carry `runs-on` edges into their runtime, and recognised stores carry `persists-to` edges into the storage system that claims their observed mechanism. Every calling surface carries a `holds` edge to the one shared transport (and to the seam it is typed against), so concurrent access to the pool and socket is visible across pages. For each function on a transport or engine owner that acquires a lock, the extracted operations are assembled into a `section` node whose steps are listed in source order with the lock-guarded ones marked (for the gateway: lock → register → unlock → send in `call`, lock → unlock → resolve in `fulfillRequest`); source order is not a claim about runtime interleaving. The drawn flow is surface → client extension → core → namespace: a surface `calls` the `client` node for the `GatewayClient+<Feature>.swift` extension whose wrappers cover the namespace it invokes, every extension `routes-through` the one core, and the core `dispatches` every namespace it serves. The core itself is drawn as a box owning its pool, lock, socket, session and critical sections. The map is laid out radially: the in-memory constructions (the transport, engines with their model containers, pool owners, and every store with no observed persistence) sit in the centre with the shared core beneath them, and the pages ring them in declared order. Every recognised data store is a construction on the map, and a surface whose file names a store gets a `uses` edge to it; a store two pages tie for takes the single page whose surfaces reference it, else stays shared: a type that is already a surface is annotated with its persistence, any other store is its own `store` node placed by page, with in-memory stores no page owns joining the in-memory hull; and an owner of a continuation pool that does not conform to the seam (the file download manager) is admitted with the `pool` role. Triggers are the first hop: a SwiftUI action or lifecycle hook whose closure calls a method on a same-file property typed as a surface (receiver-qualified) is recorded with its view, method and the namespaces the method reaches, drawn as one page → surface edge per pair labelled with counts, and listed on the surface's inspector; `calls` edges carry which triggers fire them. The transport is drawn as one in-memory construction with two legs: the request leg is the transport core, collapsed by default and expanded on click to show its pool, lock, socket, session and critical sections; the push leg is the seam's `eventStream`, which the core feeds and every subscriber in its page taps, each tap recording how the binding schedules delivery (a `collect(.byTimeOrCount)` batching window or a `receive(on:)` scheduler, read from the operator chain after the binding). Pool owners outside the transport collapse and expand the same way. A client extension sits in the page that declares ownership of its namespace. One more zone, **App launch**, is declared under `launch` in `architecture/config.json` as the directories holding the `App` entry-point structs (`App/`): every `@StateObject` those structs initialise in place is a launch trigger (the first hop before any page exists, drawn as an entry point → object edge labelled *constructs*), a recognised store referenced inside an object's `init` body is a `loads` edge, a launch-constructed type that is not otherwise on the map but loads a store is admitted as a `provider` node in the launch zone, a provider handed to a method of a type that holds the transport core gets a `configures` edge to the core (the settings object supplying the gateway URL and API key), and a store read only at launch moves from the shared core into the launch zone. System flows and the purpose of a relationship remain human-authored in `specifications/`; the boundary plane only records what the source mechanically shows.

## History: the same map at every commit

The map answers what the application looks like now. `scripts/build_architecture_history.py` (`make architecture-history`) answers when it came to look like this, without a second extractor: it re-runs `scripts/build_architecture.py --snapshot` at every first-parent commit that touched the app source (`Sources/Portal`, and `Sources/HermesNative` before the rename, extracted under today's name), with today's `config.json`, overlay and invariants, in parallel scratch trees, and writes one delta-encoded timeline to `architecture/site/history.js`. Consecutive commits are nearly identical, so a point stores only what changed against the point before it, as indices into one union table of every node and edge any snapshot contained. Nodes are keyed for diffing by `history_key`: the interplay id for everything except resources, which are re-keyed by component, owning type, kind and field name because their ids hash the declaring line.

Snapshot mode is lenient where the build is strict: an external system that matches nothing, a page root that does not exist yet, an overlay entry with no source, an evidence path that is missing, or an invariant that does not hold are recorded as that point's `fidelity` instead of failing, because the honest reading of an early point is "what today's curation can still account for of it". A commit the extractor cannot process at all is recorded under `failed`, so a hole in the axis is a stated hole; what it changed shows up on the next point that did extract.

The site loads `history.js` as an opt-in artifact and draws a **History** slider over the System map. Nodes and edges some past commit had and the head does not are folded into one layout flagged historical, so positions never reshuffle mid-slide; until the reader touches the slider they are drawn absent, and the page is byte-for-byte the head revision's map. Dragging or playing engages the timeline: what a revision lacks is absent, what the current commit removed is ghosted in dashed amber, the readout shows the commit, its counts and its diff as clickable chips, and the note states the point's fidelity gaps. **Now** (or Reset view) returns to the head revision. The inspector, the invariants dropdown and the other views always describe the head revision. The artifact is not committed: it depends on git history rather than the working tree, so `--check` cannot gate it; the Pages deploy job derives it before publishing, restoring a previous walk from the Actions cache when the extractor is unchanged so a merge costs one snapshot rather than the whole walk.

## Interplay invariants (the anti-overfitting gate)

Every rendering above assumes a construction: one transport shared by every page, pool mutations under one lock with resumes and socket writes outside it, every namespace dispatched by the core, every page owning something. Those assumptions are written down in `architecture/interplay/invariants.json`, each with a `why`, and `scripts/build_architecture.py` checks them against the extracted model on every build. A violation fails `make architecture` and `--check` with the invariant id, the offending source site, and the declared reason. Changing the construction is allowed; it requires changing the declaration in the same change, so the graph can never quietly describe code that no longer has that shape. Results are published under `interplay.invariants` and listed as plain text at the foot of the System map page, each with its status, what it pins and why; reading them never touches the graph.

## State machines

An object's lifecycle is captured mechanically where the source declares it as one: a stored property of a type on the map whose type is an enum with two or more cases and which the type assigns a case to somewhere (`swift.state.machine`). Each assignment is a transition into the case it names, attributed to the enclosing function (`swift.state.transition`); the state it leaves is read from an enclosing `switch property { case .x: … }`, `if case .x = property` or `guard case .x = property` when there is one, and left unknown otherwise rather than guessed. A derived state (a computed property switching on other fields, such as ChatViewModel's conversation phase) is not a machine. Each machine is a `machine` node in its owner's zone, linked by a `drives` edge and collapsed with a collapsible owner; its inspector renders the machine as a Mermaid state diagram generated from the transitions (an unknown origin is drawn as "any state"), lists every transition with its function and source line, and names states nothing ever enters. The `machines-complete` invariant declares each machine's states and fails the build on a new, renamed or orphaned state. Today: the transport's connection state, the chat avatar state, the gateway restart phase, and the learning store's sync availability.

## Semantic enrichment: described constructs and system flows

Two LLM-written layers sit on the mechanical map, both constrained so the compiler can reject them (design in `architecture/SEMANTIC_ENRICHMENT_PLAN.md`):

- **Construct records** (`architecture/semantic/constructs.json`): one record per construction on the System map, keyed by its `history_key`, in a kind-specific schema (`CONSTRUCT_SCHEMAS` in the compiler). A store record says its medium, location, the Swift record types it encodes, what it is keyed by, when it is written and read, its readers and writers, retention, failure mode and sensitivity; externals, the transport, engines, providers, client files, namespaces, pages, surfaces and the seam each have their own small vocabulary. Every enum value is closed, every construct key must share the right edge with the record's node, every type name must be declared in the tree, and every evidence site must lie inside the construct's bounded file set (its own file, its neighbours', the files an external's signatures matched). Records carry the revision and a hash of the files they cite; when those files change the compiler marks the record `stale`, and the inspector says so. Valid records fold onto their node as `semantic` and are shown on the inspector under **Described**; the Data stores view shows medium, record types, key and write/read timing beside each mechanical row.
- **System flows** (`architecture/semantic/flows.json`): the user's journeys as paths whose every step is an edge the map draws (by history key). Each flow belongs to one journey, `launch` (starting the app), `chat_turn` (one exchange) or `page` (entering and using one navigation page, one flow per interaction its triggers offer), names the user action or lifecycle moment that starts it, optionally starts from an observed trigger, is connected step to step, and carries a note per step and an outcome. A flow whose edge has disappeared is `broken`, and the `flows-traceable` invariant fails the build until the flow is updated in the same change. Beneath the invariants the flows are rendered inline as Mermaid sequence diagrams generated from the validated steps (participants are the nodes, the user or the App entry points first, messages are the steps with their notes), grouped in journey order: starting the app, a chat turn, then each page in declared order. A text link traces a flow on the map with the selection highlighting; node inspectors list the flows they appear in. Mermaid is loaded from a CDN after the page works without it; if it is unreachable the diagram source is shown as text.

`scripts/architecture_agent.py` writes both: `--constructs` batches constructs by kind into bounded packets (mechanical facts, the schema with its enums, fields already known mechanically, the current record, capped excerpts of the construct's own source), `--flows` runs one request per journey (launch, chat turn, each page) with that journey's scope of the graph as `[from, relation, to]` triples plus its triggers, and asks for the flows a user can start there; `--journeys page:cron` rewrites one. Responses go through the compiler's validators; anything rejected is dropped with its reason printed and the previous record kept. Providers: an OpenAI-compatible endpoint (`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `ARCHITECTURE_MODEL`) or the local `claude` CLI in print mode with structured output and no tools (`ARCHITECTURE_PROVIDER=claude-cli`, automatic when no key is set). `--stale-only` re-describes only constructs whose cited files changed. Enrichment never adds a node or an edge; nothing in placement, edges or invariants reads it.

## CI gates: the pipeline as a circuit

The **CI gates** view is a fourth deterministic plane: the repository's GitHub Actions pipeline drawn as logic gates. `scripts/build_architecture.py` reads every file under `.github/workflows` with a small YAML-subset parser (block mappings and sequences, literal and folded scalars, flow sequences; every scalar stays a string, so `on` stays `on` and a pinned `0.65.0` stays a version) and records each job with its `runs-on`, `needs`, `if`, steps, first meaningful command per step, the repository scripts each step runs, the artifacts it uploads and downloads, the tool versions it pins into a download URL, and the line of the workflow file it is declared on. `needs` and same-workflow artifact hand-offs become wires. A job is a **gate** when its workflow listens to `pull_request` and its condition does not exclude that event; every gate feeds one AND gate, the merge. Jobs whose condition excludes pull requests, or whose workflow only fires on push or a tag, are drawn after the merge; jobs only `workflow_dispatch` fires sit in a manual band; a job with `if: false` is drawn disabled.

What the workflow files cannot say is declared in `architecture/config.json` under `ci`: the family of each workflow (behavior, posture, build, publication, release, maintenance) with the question it answers, and one record per **ratchet** naming the job that enforces it, the committed file it reads (`metrics-baseline.json`, `perf-baseline.json`, `.swiftlint-baseline`, `.gitleaksignore`), what it measures, its floor rule and, where a metric is attributable to added lines, its patch rule. The compiler reads the current value of each ratchet from that file, so the view shows the numbers CI compares against rather than a fresh measurement. It fails the build when a workflow file has no family, a declared workflow has no file, a ratchet or `runs_in` entry names a job no workflow defines, or a job in the posture workflow is neither declared as a ratchet nor needed by one (the taxonomy's one-concern-per-job rule, made mechanical).

Beneath the circuit the gates are sorted by what they defend. **Ratchets** hold a metric floor. **Architectural checks** pin a shape and fail on the first violation: the `custom_rules` of `.swiftlint.yml` (with their severity, message, grandfathered file count and frozen-baseline count), the `@Test` cases of `Tests/PortalTests/ArchitectureTests.swift`, and the System-map invariants with their status on this build. **Static compiler checks** are the steps of the Pages `validate` job that run a repository script or a `--check`: they recompile a committed artifact from the tree and fail on drift. Because the model now depends on them, `.github/workflows/**`, `.swiftlint.yml`, the ArchitectureTests file and the four baselines are Pages trigger paths, and `make metrics-baseline` / `make perf-baseline` regenerate the model after rewriting a baseline.

The view does not read branch protection: a gate here is a job that runs on pull requests, not a proof that GitHub requires it. Nothing here proves a job ran or passed.

## The model as a service standard

The model this compiler emits is also what Portal and Harness exchange for any service. A service that conforms ships a compiler that writes `architecture/model/model.json` and a `--check` that fails on drift; a manifest under `~/.hermes/services/architecture/<id>.json` (a local checkout that is never pushed, or a GitHub repository at a ref) tells Harness where to read it. Harness snapshots the model per revision, runs the check on demand and serves it over `architecture.*`; the service appears on Portal's dataflow graph with its source files, and **View architecture** on the node opens the model in this very renderer. To make that possible the compiler also emits `Sources/Portal/Models/ArchitectureObservatoryAssets.swift`, the site's `index.html`, `app.js` and `styles.css` as Swift constants, so the in-app page and the published site are the same code; `--check` fails when they drift. Portal is the first registered service. Contract: `harness/docs/api/architecture.md`.

## Local development

```bash
make architecture
make architecture-check
make architecture-history   # optional: the System map at every commit (a few minutes)
make architecture-serve
```

The preview is served at <http://127.0.0.1:4173/>. Generated model and site-data files are checked in so pull requests show the exact architecture change that will be published. `architecture/site/history.js` is the exception: it is derived from git history, ignored by git, and built on demand.

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

`.github/workflows/architecture-pages.yml` validates the checked-in model, tests the compiler, checks browser JavaScript, and deploys `architecture/site/` after a merge to `main`, deriving `history.js` first (cached between deploys by extractor fingerprint).

GitHub Pages must be configured once with **Source: GitHub Actions** in repository settings. The expected public URL is <https://ethenotethan.github.io/portal/>.

## Adding a component

1. Add a component and ordered path patterns to `architecture/config.json`.
2. Add explicit architectural relationships with source evidence when the relationship carries architectural meaning.
3. Run `make architecture`.
4. Run `make architecture-check`.
5. Review the graph and source inventory locally.

Patterns are first-match-wins. Feature-specific patterns must precede fallback components such as `local-services`, `domain-models`, and `shared-ui`.
