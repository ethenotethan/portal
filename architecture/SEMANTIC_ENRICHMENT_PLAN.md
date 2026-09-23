# Semantic enrichment plan: constrained text on a mechanical map

Status: plan, 2026-09-23. Nothing below is built yet except where marked *exists*.

## The problem

The System map is derived from source by rules, so it can say *that* `KeychainStore`
persists to the Keychain, *that* `SettingsViewModel` reads it in `init`, and *that*
seven pages hold the transport core. It cannot say what is stored, in what shape, under
which key, when it is written, or why. A reader looking at the Data stores view today
sees a mechanism (`file`, `defaults`, `keychain`, `unobserved`) and artifact names, and
has no idea what the record is or who owns its lifecycle. Likewise the map draws every
wire but no story: github-flashlight's write-up names five key flows (prompt → stream,
local voice inference, thought graph, wiki, skills) as prose and sequence diagrams that
float free of any graph; ours has the graph and no flows.

Two layers of enrichment close that gap, both LLM-written, both constrained so hard that
the compiler can reject them:

1. **Construct records**: one bounded JSON record per construction on the map (store,
   external, transport owner, engine, provider, client file, namespace, page), in a
   schema fixed per kind, whose every identifier must exist in the mechanical model.
2. **System flows**: named end-to-end flows whose steps are edges that exist in the
   mechanical graph, so a flow is a path *on* the System map, not a diagram beside it.

## Principles

- **Mechanical first, text second.** Enrichment never adds a node or an edge. It
  annotates constructs the compiler already extracted and traces paths over edges the
  compiler already drew. If the model wants to name something that is not on the map,
  the right output is an `open_question`, and the right fix is a new extraction rule.
- **Closed vocabularies wherever possible.** Every field is an enum, an id from the
  model, a source path from the construct's bounded file set, or a short string with a
  length cap. Free prose is limited to one `summary` per record and one `note` per step.
- **Evidence or silence.** Every record and every step cites `path:line` inside the
  files the compiler attributes to that construct (or to the edge's two endpoints).
  The validator rejects citations outside that set, exactly as the overlay gate does.
- **Staleness is shown, not hidden.** Each record carries the `source_revision` and the
  hash of the files it cites. The compiler marks a record `stale` when those files
  changed since; the site draws it that way and the maintenance run re-summarises it.
- **Same gates as the rest of the observatory.** Malformed, out-of-vocabulary or
  stale-beyond-tolerance records fail `make architecture --check` and CI, the way an
  unexplained resource or a violated invariant does today.

## What exists

- `architecture/semantic/components.json` (*exists*): one record per **component**
  (nine of them) with `summary`, `responsibilities`, `flows` (free strings),
  `open_questions`, `evidence`, `source_revision`, `model`. Folded into `components[]`
  by `load_semantic`, shown on the component inspector. Its `flows` are unstructured
  sentences, not paths.
- `scripts/architecture_agent.py` (*exists*): builds a packet per changed component
  (mechanical facts + bounded source paths), prompts an OpenAI-compatible endpoint
  (`ARCHITECTURE_OPENAI_API_KEY`, `ARCHITECTURE_OPENAI_BASE_URL`, `ARCHITECTURE_MODEL`),
  validates the JSON (ids and evidence paths must come from the packet), merges, and
  the maintenance workflow opens a PR. The write path is semantic-only (tested).
- `architecture/interplay/overlay.json` (*exists*): human prose for load-bearing
  resources, gated both ways (unexplained source fails; stale prose fails).

The plan generalises these three things from *component* to *construct* and from
*sentence* to *path*.

## Layer 1: construct records

New file `architecture/semantic/constructs.json`, schema `1.0.0`, one array `records`.
Each record is keyed by the construct's interplay `history_key` (stable across renames
of the transport and re-numbering of lines), carries `kind`, and then a kind-specific
body. Common fields on every record:

| field | type | rule |
|---|---|---|
| `key` | string | must equal a `history_key` in `interplay.nodes` |
| `kind` | enum | must equal that node's kind |
| `summary` | string ≤ 400 chars | one paragraph, present tense, describes current source |
| `evidence` | `[{path, line}]` ≥ 1 | paths within the construct's files (its declaring file, same-file extensions, and the files of nodes it has edges to) |
| `open_questions` | `[string ≤ 200]` | anything the evidence does not settle |
| `source_revision`, `cited_hash`, `model` | strings | written by the agent; `cited_hash` is the sha256 of the cited files at that revision |

Kind bodies (the closed part of the vocabulary):

**store** — the case that prompted this plan.

| field | type | pre-filled mechanically? |
|---|---|---|
| `medium` | enum `json_file` · `plist_file` · `sqlite` · `user_defaults` · `keychain` · `in_memory` · `mixed` | yes, from `persistence` (the model may only refine `file` → `json_file`/`plist_file`/`sqlite`) |
| `location` | string ≤ 120 (directory or defaults suite / keychain service) | partially, from artifact literals |
| `record_type` | `[type name]` — the Swift types that are encoded/decoded | no; must be declared types in the source tree |
| `keyed_by` | string ≤ 80 (`"UUID id"`, `"gateway URL"`, `"session id + page"`) | no |
| `written_when` | `[enum]` `on_change` · `debounced` · `on_background` · `on_launch` · `explicit_save` · `never` | no |
| `read_when` | `[enum]` `on_launch` · `on_page_appear` · `on_demand` · `on_event` | partially: `loads` edges imply `on_launch` |
| `readers`, `writers` | `[history_key]` | validated against `uses` / `loads` edges: a listed reader must have an edge to the store |
| `retention` | enum `forever` · `bounded_count` · `bounded_age` · `session` | no |
| `failure_mode` | enum `throws` · `logs_and_continues` · `silent` · `resets_store` | no |
| `sensitive` | bool | `keychain` ⇒ true is enforced |

**external** — `protocol` (enum), `auth` (enum `none` · `api_key` · `oauth` · `device_token` · `entitlement`), `direction` (`outbound` · `inbound` · `both`), `failure_visible_as` (string ≤ 120), `namespaces_or_apis` (`[string]`, for the gateway these must be endpoint labels on the map).

**owner with transport role** — `concurrency_model` (enum `main_actor` · `actor` · `lock_guarded` · `queue_confined`), `reconnect_policy` (string ≤ 160), `backpressure` (enum), `shared_by` (`[page id]`, validated against `holds` edges).

**engine** — `runtime` (must be an external key), `model_ids` (`[string]`, validated as string literals present in the file set), `memory_floor_gb` (int, optional), `loaded_when` (enum), `unloaded_when` (enum).

**provider** — `supplies` (`[string ≤ 60]`), `configures` (`[history_key]`, validated against `configures` edges), `loads` (`[history_key]`, validated against `loads` edges).

**client file** — `wraps` (`[endpoint key]`, validated against `implements`), `error_mapping` (string ≤ 160).

**endpoint namespace** — `purpose` (≤ 200), `request_shape`, `response_shape` (≤ 120 each), `idempotent` (bool), `streams` (bool).

**page** — `purpose` (≤ 200), `entry_triggers` (`[trigger id]`), `owns_state_in` (`[history_key]`, validated against nodes with that `page`).

The compiler folds each valid record onto its node as `node.semantic`, computes
`stale`, and the inspector shows the kind body as a labelled table under a
"Described" heading, with the summary above it, the evidence links below, and a
`STALE · files changed since <rev>` badge when appropriate. The Data stores view gets
`medium · record_type · keyed_by · written_when` columns, which is the direct answer to
"what is the data type, what is the database, how is it referenced".

## Layer 2: system flows mapped onto the graph

New file `architecture/semantic/flows.json`, schema `1.0.0`, one array `flows`.

```json
{
  "id": "prompt-to-stream",
  "title": "Prompt to streamed reply",
  "summary": "A typed prompt leaves the chat surface, rides the shared transport as a JSON-RPC call, and comes back as deltas on the event stream.",
  "trigger": "<id of the ChatView onSubmit trigger in interplay.triggers>",
  "steps": [
    {"from": "caller:chat-state:ChatViewModel", "to": "owner:hermes-services:GatewayClient", "relation": "holds", "note": "the surface holds the one shared transport"},
    {"from": "caller:chat-state:ChatViewModel", "to": "endpoint:jsonrpc:prompt", "relation": "invokes", "note": "submitPrompt call site"},
    {"from": "owner:hermes-services:GatewayClient", "to": "endpoint:jsonrpc:prompt", "relation": "dispatches", "note": "correlated through pendingRequests under the lock"},
    {"from": "owner:hermes-services:GatewayClient", "to": "resource:backend-contract:AgentBackend:event_bus:eventStream", "relation": "provides"},
    {"from": "resource:backend-contract:AgentBackend:event_bus:eventStream", "to": "hub:ChatViewModel", "relation": "notifies", "note": "batched 32 ms / 30 events onto RunLoop.main"}
  ],
  "outcome": "ChatView re-renders per delta; the pool entry is removed on the final frame.",
  "evidence": [{"path": "Sources/Portal/ViewModels/ChatViewModel.swift", "line": 736}],
  "source_revision": "…", "model": "…"
}
```

Rules the compiler enforces:

- `trigger`, if present, is a trigger id in `interplay.triggers`, and its surface is the
  `from` of the first step (a flow starts where a user or the launch starts it). Every
  step in the example above is an edge in today's model; a `calls` step through a
  client extension file would be required instead for namespaces that have one.
- Every step's `(from, to, relation)` is an edge in `interplay.edges` (history keys),
  or a containment the map draws as such (`served-by` into a gateway). A step over an
  edge that does not exist is a schema error, not a warning.
- Steps are connected: each `from` equals the previous `to`, or is a node the previous
  steps have already visited (so fan-out like "core → endpoint" and "core → event
  stream" is expressible).
- 3 ≤ steps ≤ 12; `note` ≤ 120 chars; at most one `summary`.
- A new invariant, `flows-traceable`, fails the build when any declared flow has a step
  whose edge has disappeared, the same way the overlay fails on stale prose. Changing
  the construction is allowed; it requires updating the flow in the same change.

Rendering, on the System map page beneath the invariants:

- A **System flows** list: title, summary, step count, trigger. Plain text, like the
  invariants. Each has one button, *Trace on map*.
- *Trace* highlights the flow's edges and nodes with the existing selection mechanics
  (`active` edges, relation labels, everything else dimmed), numbers the steps along
  the path, and opens the flow's text in the side panel. Clearing the selection or
  pressing Reset view returns the map to rest. Nothing about the layout changes.
- The node inspector lists "Appears in flows" with links that trace them.
- With the history slider engaged, a step whose edge is absent at that commit is drawn
  dashed, so a flow shows when it became possible (this is cheap once steps are edge
  keys; it is not in the first phase).

Seeds, taken from flashlight's list and checked against edges that exist today:
prompt → streamed reply; local voice inference (voice trigger → LocalChatService →
MLX engine → TTS); event stream → activity inbox; wiki/graphs query; skills load;
launch → keychain → gateway connect (the chain that motivated the launch zone).

## Pipeline

Generalise `scripts/architecture_agent.py` rather than adding a second agent:

1. **Packets per construct**, not per component. A packet carries the node's mechanical
   record (kind, edges with relation names, page, persistence, artifact literals,
   triggers, sections), the schema for its kind with the enums spelled out, the fields
   already pre-filled mechanically (which the model may refine but not contradict), the
   current record if any, and bounded excerpts: the declaring type body, its `init`,
   and the signatures of methods that touch the store/transport. Excerpts are capped
   (≈ 6k tokens per packet); nothing outside the construct's file set is sent.
2. **One flow packet**: the whole interplay graph as `(from, relation, to)` triples over
   history keys plus the trigger table and the existing flows, with the instruction to
   return flows that use only listed triples. This is the flashlight-style "identify
   key system flows" step, constrained to the graph.
3. **Validate** with the compiler's own validators (import, do not duplicate): unknown
   key, wrong kind, enum miss, evidence outside the bounded set, step over a missing
   edge → reject that record, keep the previous one, and record the rejection reason
   in the run log. Never write partial records.
4. **Merge and stamp** `source_revision`, `cited_hash`, `model`; rebuild; run
   `--check` and the tests; open or update the maintenance PR (existing workflow).
5. **When to run**: on the maintenance workflow as today (manual and via the Hermes
   documentation worker), scoped to constructs whose `stale` flag is set, plus
   `--all` for a full pass. A store, external or flow that is `stale` for more than
   N merged commits (config, default 20) fails `--check`, so text cannot rot silently.
6. **Model**: provider-neutral through the existing OpenAI-compatible variables; for a
   first pass use the strongest available model and keep `model` on every record.

## Anti-overfitting and review

- The validator is the contract. No rule in the compiler may read `semantic` fields to
  decide placement, edges or invariants; enrichment is display-only and the test
  `architecture_agent_write_path_is_semantic_only` extends to `constructs.json` and
  `flows.json`.
- Every run is a PR with the diff of two JSON files; a reviewer sees each claim next to
  its `path:line`. Records are short enough to read.
- Two synthetic-drift tests: a record citing a file outside its set must fail; a flow
  with a step over a removed edge must fail `flows-traceable`.

## Phases

1. **Stores and externals** (schema, validator, inspector table, Data stores columns,
   agent packets for those two kinds). First pass generated, reviewed by hand, merged.
   This answers the question that started the thread.
2. **Flows** (schema, `flows-traceable` invariant, list under the map, *Trace on
   map*, inspector cross-links). Seed the six flows above through the agent, review.
3. **Remaining kinds** (transport, engines, providers, client files, namespaces, pages)
   and the staleness gate in CI.
4. **Flows over history**: dashed steps under the slider; optional.

Each phase is one PR; each is useful on its own; none changes the mechanical model.
