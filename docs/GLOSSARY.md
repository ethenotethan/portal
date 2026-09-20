# Portal Glossary

Every definition below is distilled from the `///` documentation already in
`Sources/Portal` — 2,966 doc blocks across 1,021 type declarations. Where a
concept has no doc comment anywhere, it is marked **(undocumented)**: that is
itself a finding, not an omission here.

Read this as the vocabulary the codebase *already* speaks. Where two names mean
one thing, or one name means two things, the entry says so and points at
`docs/NAMING-COLLISIONS.md` for the merge recommendation.

---

## 1. Backends and connections

**Backend** — the agent platform behind the chat UI. `AgentBackend`
(`Services/AgentBackend.swift:17`) is "the backend surface ChatViewModel
actually consumes, extracted so a second agent platform (Centaur — REST + SSE)
can sit behind the same chat UI as the Hermes gateway (WebSocket JSON-RPC)".
Events arrive as `GatewayEvent` regardless of backend.

**Gateway** — the Hermes backend specifically: a WebSocket JSON-RPC server.
`GatewayClient` (`Services/GatewayClient.swift:32`) is its client, with
ping/pong keepalive, exponential-backoff reconnect and session resume.
*In prose, "gateway" is also used loosely for "whichever backend is
connected" — see the Harness entry.*

**Harness** — the user-facing name for a configured backend connection (URL +
auth + kind). **(undocumented as a type.)** Surfaces: `HarnessConnectionSection`,
`HarnessConnectionStatus`, the Harnesses sidebar. `BackendKind` distinguishes
Hermes / Hermes Standard / Centaur.

**Hermes Standard** — an upstream/default Hermes install managed over plain
HTTP. `HermesStandardClient` (`Services/HermesStandardClient.swift:158`)
"intentionally does not conform to AgentBackend: this surface manages a Hermes
installation but cannot create or stream Portal chat sessions". Its payloads are
bridged into native models by `HermesStandardMappers`.

**Capabilities** — two distinct things share this word:
- `GatewayCapabilities` (`Models/GatewayCapabilities.swift:3`) — "normalized
  capability data reported by the connected gateway". Runtime data, fetched.
- `BackendCapabilities` (`Services/AgentBackend.swift:114`) — "feature flags a
  backend advertises so the UI can hide what can't work". Compile-time
  constants (`.hermes`, `.centaur`).

**Connection state** — `GatewayClient.ConnectionState`, with presentation rules
centralized so "every surface agrees on what green/amber/red means"
(`Views/HarnessConnectionStatus.swift:6`).

---

## 2. Sessions, turns and identity

**Session** — "a Hermes agent session. Fields match the gateway's
`session.list` response schema" (`Models/Session.swift:48`).

**Session identity (dual)** — a session has two IDs and the codebase names them
inconsistently. `SessionListViewModel` (`ViewModels/SessionListViewModel.swift:8`)
"tracks the mapping between database IDs (from session.list) and gateway
in-memory IDs (short hex, from session.create) so RPCs work".
- *Display / stable ID* — the durable database ID (`20260501_112429_d91274`).
  Named `id`, `sessionID`, `displayID`, `currentSessionID`, `sourceSessionID`.
- *Runtime / gateway ID* — the short-hex in-memory ID. Named `runtimeID`,
  `gatewayID`, `activeSessionID`, `sessionKey`, `rpcID`, `gwID`; Centaur calls it
  `thread_key`.

  Note `resumeSession(key:)` takes the **stable** ID despite `key` meaning the
  runtime ID elsewhere.
  Canonical accessor: `Session.rpcID = gatewayID ?? id`.
  Bridge: `bindRuntimeSession(displayID:runtimeID:)`.
  → 13 names for 2 concepts. See collisions report §S1.

**Turn** — one user prompt plus the assistant's full response. There is no
`Turn` type; the concept lives in `ChatMessage`, `TurnGraphSnapshot`
("the thought-graph depth for one turn, snapshotted at message-complete",
`Models/ChatMessage.swift:261`), `TurnSkillRecord`, and `SessionTurn`
("one turn's worth of thought-graph data, reconstructed from a persisted
assistant `ChatMessage`", `Views/ThoughtGraph/SessionThoughtGraphView.swift:5`).

**Message** — "a single message in the chat conversation" (`Models/ChatMessage.swift:3`).

**Session status vs run state** — two orthogonal axes, correctly separated:
- `SessionStatus` (`Models/Session.swift:3`) — "activity status for a session,
  derived from `lastActive` and `endedAt`". Is this session alive at all?
- `SessionRunState` (`Models/Session.swift:13`) — "best-known run state for the
  latest execution in a session… Portal derives a conservative state from
  existing session list timestamps". Is a turn executing right now?

**Live / streaming / running** — one concept, three words. `SessionRunState`'s
own decoder normalizes the gateway's `streaming` / `active` / `running` /
`in_progress` to `.streaming`, which is the codebase admitting the synonym set.
Portal-side names: `isStreaming`, `streamingSessionIDs`, `localRunStates`,
`RunStatus`, `SessionRunEvent`. See §S2.

**Runtime state cache** — `SessionRuntimeState`
(`ViewModels/ChatViewModel.swift:342`, **undocumented**), the per-session
snapshot `ChatViewModel` keeps so switching sessions restores messages, model
badge, skills and response style without a refetch.

---

## 3. Events

**Gateway event** — "typed representation of all gateway event types the server
can emit. Each case carries a strongly-typed payload where possible. Source:
tui_gateway/server.py `_emit()` calls" (`Models/GatewayEvent.swift:3`). This is
*the* event type of the chat pipeline.

**Raw session event** — "one raw wire event from a backend's session event log —
a Sendable snapshot of an SSE frame (id + event name + data)… The chat pipeline
adapts these into `GatewayEvent`s and intentionally drops lifecycle noise; the
Explorer's Events tab shows them verbatim" (`Services/RawEventLog.swift:5`).

**Wiki event** — a *different* sense: "one raw INPUT event that flowed into a
knowledge base" (`WikiTimelineEvent`, `Models/WikiEventTimeline.swift:63`) —
an ingestion source, not a stream frame. The taxonomy that says what a trigger
MEANS lives in `WikiGraphViewModel+EventTypes`
(`ViewModels/WikiGraphViewModel+EventTypes.swift:3`). See §H4.

**Payload** — the typed body of one event case (`ToolStartPayload`,
`ApprovalPayload`, `SubagentCompletePayload`, …). 11 types, consistent usage.

---

## 4. Blocks, specs and artifacts

**Block** — a fenced code region in an assistant message that Portal renders as
a rich surface instead of text.

**Block spec** — the JSON contract for one fenced block kind. The doc comments
use a literal shared formula — "JSON contract for ```` ```chart ```` fenced
blocks emitted by the assistant" — across `ChartSpec`, `SankeySpec`, `ModelSpec`,
`DatasetSpec`, `KanbanSpec`, `CalendarSpec`, `ChecklistSpec`, `MapSpec`,
`NetworkGraphSpec`, `StatTileSpec`, `TimelineSpec`, `Model3DSpec`.
**`*Spec` = declarative payload parsed from agent output.** Cleanest family in
the codebase; treat it as the naming template for new render blocks.

**Artifact** — three unrelated concepts wear this name:
- `Artifact` (`Views/Blocks/ArtifactPanel.swift:8`) — "a block of generated
  content promoted out of the transcript into the side panel: code, a diff, or a
  whole markdown document. Identity is the content hash."
- `LivingArtifact` (`Models/LivingArtifact.swift:3`) — "a named, persistent
  artifact the agent maintains across turns and sessions — an arbitrary model,
  not a message. Any fenced block carrying an `"id"` upserts into the store."
- `ActivityArtifact` (`Models/ActivityItem.swift:101`, **undocumented**) — a
  payload attached to an inbox activity item.

  Only the middle one is persisted server-side (`ArtifactStore`,
  `Services/ArtifactStore.swift:7`, "store for living artifacts: named models ANY
  writer maintains"). See §H1.

**Intent** — a declared action a block exposes (`ArtifactIntent`,
`ArtifactActionInvokeResult`, `ArtifactIntentSessionLink`,
`IntentInvocationState`). **(undocumented at the type level.)**

---

## 5. Tools, reasoning and delegation

**Tool call** — "record of a tool invocation within a conversation turn"
(`ToolCallRecord`, `Models/ChatMessage.swift:291`).

**Thought graph** — "the full thought graph for a single conversation turn (one
assistant message). Represents the live DAG of tool invocations during active
streaming" (`ThoughtGraph`, `Models/ThoughtGraphNode.swift:270`). A node is "one
tool invocation during an active chat streaming turn"
(`ThoughtGraphNode`, `Models/ThoughtGraphNode.swift:5`).

**Lane / swimlane** — "one horizontal swimlane: the main loop or a single
subagent's loop. Lanes stack down the y-axis; time runs left→right"
(`ThoughtGraphLane`, `Views/ThoughtGraph/ThoughtGraphLayoutEngine.swift:24`).
The graph "reads as a flamechart of the react loop — a box's horizontal position
is WHEN it happened and its width is HOW LONG it took"
(`ThoughtGraphLayoutEngine`, same file, L41).

**Reasoning beat** — one unit of the model's thinking, linkable to the tool calls
that "act on the same CONCEPT — drawn as faint edges on the timeline so 'I should
check the status MD file' visibly connects to the `read status.md` call"
(`ConceptLink`, `Models/ConceptLinker.swift:3`).

**Spawn tree** — "a node in the agent's spawn tree — represents a root prompt or
a subagent. Recursive: root prompt → children (delegated subagents) → their
children" (`SpawnNode`, `Models/SpawnNode.swift:14`); accumulated live by
`SpawnTreeStore` (`ViewModels/SpawnTreeStore.swift:4`).

**Delegation batch** — a group of subagents launched together.
`DelegationBatchRecord` (`Models/DelegationBatchRecord.swift:30`) is "a persisted
snapshot of a finished delegation batch — the durable counterpart to the live
`DelegationBatch`… Only *terminal* batches are recorded."
→ The **live X / persisted XRecord** pair is a deliberate, documented pattern;
`CronRunRecord` follows it explicitly ("mirrors `CronRunRecord`").

---

## 6. Models (the LLM sense)

**Model** — the LLM serving a turn. `ModelCatalog`
(`Models/ModelCatalog.swift:3`) is the "decoded `model.options` RPC payload: the
gateway's live model inventory, grouped by provider… the same substrate the TUI's
model picker dialog renders."

**Pinned vs routed** — a session whose model is chosen per-turn reports
`model: ""` from `session.info`. The field means *"no pinned override"*, not
*"no model"*; `ModelCatalog` is the only source of the effective model.
Documented as a trap in `Tests/PortalTests/ModelBadgeTests.swift:5`.

**Model, other senses** — `ModelSpec` is an *ensemble artifact* block
("named ENTITY SETS, RELATIONS between entities, and stacked VIEWS",
`Models/ModelSpec.swift:3`); `Model3DSpec` is a 3-D scene; `*ViewModel` is the
MVVM layer. Four senses of one word. See §H5.

---

## 7. Graphs

Portal ships six distinct graph surfaces. They agree on **Node** and disagree on
the edge word:

| Surface | Node type | Edge type | Layout |
|---|---|---|---|
| Thought graph | `ThoughtGraphNode` | `ThoughtGraphEdge` | `ThoughtGraphLayoutEngine` |
| Cron interflow | `CronGraphNode` | `CronGraphEdge` | inline force settle |
| Skill graph | `SkillGraphNode` | `SkillGraphEdge` | web view |
| Wiki graph | `WikiPage` | `WikiLink` | off-main-thread physics |
| Network block | `Node` (nested) | `Link` (nested) | `NetworkGraphLayout` |
| Sankey block | implicit | `Link` (nested) | `SankeyLayout` |

**Edge vs Link** — same concept, split by neighbourhood. See §S3.

**Physics node** — the mutable simulation particle (`position`, `velocity`,
`isDragging`). Declared twice, independently: `CronGraphViewModel.SimNode:17`
and `WikiGraphViewModel.SimNode:158`. See §H2.

**Layout** — four incompatible meanings. See §H3.
- *Algorithm*: `NetworkGraphLayout` ("one-shot force-directed layout… runs to
  convergence at parse time", `Models/NetworkGraphSpec.swift:110`),
  `SankeyLayout` ("column-and-ribbon layout… deterministic and pure",
  `Models/SankeySpec.swift:83`), `ThoughtGraphLayoutEngine`.
- *Per-node result*: `ThoughtGraphLayout` — "layout information for a single
  node… computed position and size" (`Models/ThoughtGraphNode.swift:320`).
- *User's saved arrangement*: `DashboardLayout` — "the user's arrangement of
  panels on the thought-graph dashboard canvas… Ordered back-to-front"
  (`Models/DashboardLayout.swift:7`).
- *SwiftUI `Layout` protocol*: `FlowLayout`, `ChipFlowLayout`.

---

## 8. Wiki

**Wiki** — "the LLM Wiki knowledge base" of pages and links (`WikiPage`,
`Models/WikiGraph.swift:3`; `WikiLink`, L29).

**Changeset** — one recorded edit to the wiki, fetched via `wiki.changesets` /
`wiki.changeset_diff` (`Services/WikiChangesetSource.swift:15`).

**Provenance** — "page ⇄ changeset ⇄ event. Both directions live here because
they're one relationship read from two ends, and reading them side by side is how
you see that they stay inverse"
(`ViewModels/WikiGraphViewModel+Provenance.swift:3`).

---

## 9. Skills

**Skill** — a named capability the gateway can enable per session.
`Skill` / `SkillInfo` (`Models/Skill.swift:3`) are **undocumented**;
`CachedSkillInfo` and `StoredSkillInfo` are the persistence shapes.

**Skill cache/store** — one concept, four types, one of them dead:
`SkillStore` (live, `Services/SkillStore.swift:189`, `@Observable`, 39 refs,
**undocumented**), `SkillCache` (documented at `Services/SkillCache.swift:100` —
"shared skill cache that persists across navigations. Background-refreshes on a
timer… publishes diff-based updates" — but **zero references outside its own
file**), plus `SkillStoreDisk` and `SkillCacheDisk`. See §D1.

---

## 10. Cron

**Cron job** — "a scheduled cron job from the gateway's `cron.manage`
(action: list) response" (`Models/CronJob.swift:3`).

**Cron reads as a specialized session** — stated outright: `CronFilterState`
"mirror[s] `SessionsFilterState` so a cron reads like a specialized session…
Cron-specific dimensions (a job's enabled/paused state and last-run health) stand
in for a session's live/ended status" (`ViewModels/CronFilterState.swift:3`).

**Cron interflow graph** — "jobs + their sources / artifacts / sinks"; the view
model "runs a small synchronous force layout… the wiki graph's off-main-thread
physics engine is overkill" (`ViewModels/CronGraphViewModel.swift:6`).

---

## 11. Learning

**Curriculum** — "a structured course: ordered modules, each holding ordered
steps that are either a written lesson or a quiz. Unlike a standalone quiz or
deck, a curriculum tracks *per-step* progress" (`Models/Learning/Curriculum.swift:3`).

**Quiz vs quiz state** — a documented, deliberate split:
`CurriculumViewModel` "reuses `QuizState` rather than `QuizViewModel`.
`QuizViewModel` owns a save-and-clear lifecycle… which would both fight
step-to-step navigation and litter the Learning list with a standalone quiz
record per module quiz. Here the score belongs to the step."
(`ViewModels/Learning/CurriculumViewModel.swift:6`).

**SRS** — "SM-2 spaced repetition state for a single flashcard"
(`SRSState`, `Models/Quiz/FlashcardModels.swift:66`).

---

## 12. Dashboard

**Panel** — "one panel on the dashboard canvas: a kind (what it shows) placed at
a frame (where and how big)… z-order is the panel's position in
`DashboardLayout.panels` (last = top)" (`Models/DashboardPanel.swift:118`).
20 `*Panel` types; the word is used consistently.

---

## 13. Theme

**Theme** has three layers and the names don't say which is which:
- `AppTheme` (`Views/Theme.swift:11`) — "a complete color palette. New presets
  are cheap to add." A `Codable` **preset record** carrying hex strings
  (…and some geometry, e.g. `AppTheme.pillRadius`).
- `ThemeManager` (`Views/Theme.swift:195`) — "singleton holding the active
  palette. Observers re-render on change. Persisted to UserDefaults."
- `Theme` (`Views/Theme.swift:401`) — a static facade enum over
  `ThemeManager.shared.colors`, ~1,560 call sites. **The thing you actually
  use.**
- `ThemeColors` (`Views/Theme.swift:352`) — decoded `Color` values.
- Sub-themes: `ButtonTheme`, `ToolbarIconTheme`, `AppFontTheme`.
  See §H6.

---

## 14. Role suffixes (the codebase's own type taxonomy)

Derived from the 838 top-level type names. These are consistent enough to treat
as rules for new code:

| Suffix | Count | Means |
|---|---|---|
| `*View` | 135 | a SwiftUI view |
| `*Card` / `*Row` / `*Panel` / `*Section` | 83 | a view of a specific shape |
| `*ViewModel` | 16 | `@MainActor ObservableObject` driving one surface |
| `*Store` | 14 | owns a collection + persistence (memory → disk → gateway) |
| `*Client` | — | speaks one wire protocol to one backend |
| `*Service` | 9 | stateless-ish capability (TTS, notifications, push) |
| `*Manager` | — | singleton owning one global concern |
| `*Spec` | 12 | JSON contract for an agent-emitted fenced block |
| `*Payload` | 11 | typed body of one gateway event case |
| `*Record` | 7 | persisted, id-keyed snapshot of something terminal |
| `*Info` | 7 | decoded read-only report from a backend |
| `*Ref` | 8 | a pointer to an entity by key, not the entity |
| `*Error` | 10 | typed failure |
| `*State` | 23 | **overloaded** — see §H7 |
| `*Layout` | 8 | **overloaded** — see §H3 |
| `*Kind` / `*Status` / `*Mode` | 36 | small enums; the three words are not distinguished |

`*Store` vs `*Cache` vs `*Manager` vs `*Service` have no documented boundary;
`ArtifactStore`'s doc ("three layers: in-memory published dictionary → disk →
gateway") is the closest thing to a definition of `*Store` and is worth
promoting into a rule.

---

## 15. Cross-cutting conventions worth naming

**Live vs persisted pairing** — `DelegationBatch`/`DelegationBatchRecord`,
`CronJob`/`CronRunRecord`, `ThoughtGraph`/`TurnGraphSnapshot`. Documented as
intentional in each case. Good pattern; name new pairs the same way.

**Disk sidecar** — `SkillStoreDisk`, `SkillCacheDisk`, `WikiGraphCache`
("all disk access off the main actor"). A `*Disk` enum is the pure
load/save namespace for its owner.

**Nonisolated physics snapshot** — `Physics2DParams` is an "immutable snapshot of
the 2D force constants so the physics step can run as a `nonisolated static`…
without touching @MainActor instance state"
(`ViewModels/WikiGraphViewModel.swift:985`). The pattern to copy for any
main-actor-hostile compute.

**Declaration-only conformance** — `extension GatewayClient: X {}` with the doc
"already implements every member with these exact signatures, so conformance is
declaration-only" (`Models/DomainProtocols.swift:67`, L115).
