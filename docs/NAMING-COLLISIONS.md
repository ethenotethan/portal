# Naming Collisions and Regressions

Companion to `docs/GLOSSARY.md`. Every finding is derived from the codebase's own
doc comments plus a declaration/reference census (838 top-level types, 2,966 doc
blocks). Each entry gives the evidence, the cost, and a merge recommendation.

Findings are grouped by kind:

- **§H — Homonyms**: one name, several concepts. Highest cost; readers guess wrong.
- **§S — Synonyms**: several names, one concept. Costs a lookup per read.
- **§D — Drift / regressions**: docs and code disagree, or a documented type is dead.

Ranked most-costly first within each group.

---

## §H — Homonyms (one name, several concepts)

### H1. "Artifact" means three unrelated things

| Type | Concept | Site |
|---|---|---|
| `Artifact` | a transcript block promoted into the side panel; identity = content hash | `Views/Blocks/ArtifactPanel.swift:8` |
| `LivingArtifact` | a *named, persistent model* the agent maintains across sessions, synced via `artifact.*` RPCs | `Models/LivingArtifact.swift:3` |
| `ActivityArtifact` | a payload attached to an inbox activity item (**undocumented**) | `Models/ActivityItem.swift:101` |

The bare name `Artifact` went to the *least* durable of the three, while the
concept the gateway itself calls "artifact" is the one that needed the qualifier.
`ArtifactStore` stores `LivingArtifact`s — not `Artifact`s — so
`ArtifactStore`/`Artifact` read as a pair and are not one.

Also in the family: `ArtifactPanel`, `ArtifactPanelContent`, `ArtifactCanvasView`,
`ArtifactDetailView`, `ArtifactHistoryView`, `ArtifactHTMLIntentView`,
`ArtifactMaintenanceSection`, `ArtifactParseError`, `ArtifactPointerLockDelegate`,
`ArtifactIntent*` — some belong to the panel sense, some to the living sense.

**Recommendation.** Rename to make the durable one unqualified and the ephemeral
one explicit:
- `LivingArtifact` → `Artifact` (it is the domain artifact; 52 refs)
- `Artifact` → `PanelBlock` or `PromotedBlock` (it is a *block*, per its own doc; 29 refs)
- `ActivityArtifact` → `ActivityAttachment`

Then audit the `Artifact*` view names to sit under whichever sense they serve.
Do not attempt a type-level *merge* — the three concepts are genuinely distinct;
the fix is naming, not unification.

### H2. `SimNode` declared twice, independently

`ViewModels/CronGraphViewModel.swift:17` and
`ViewModels/WikiGraphViewModel.swift:158` each declare a nested
`struct SimNode: Identifiable` with the same core fields (`id`, `position`,
`velocity`, `isDragging`). Wiki's adds 3-D (`position3D`, `velocity3D`); cron's
adds `kind`/`type` domain tags.

The duplication is *explained* by `CronGraphViewModel`'s own doc ("the wiki
graph's off-main-thread physics engine is overkill — a synchronous settle plus a
30 Hz live tick keeps the code small"), so it is a deliberate fork of the
*engine* — but it forked the *data type* too, and that was not the intent.

**Recommendation.** Extract one `ForceNode` (id, position, velocity, isDragging)
into `Models/`, generic or with a `payload`/`kind` field, and let both view models
compose it. `Physics2DParams` (`WikiGraphViewModel.swift:985`) is already the
right shape for the shared constants — promote it alongside. This is a true merge:
same concept, same fields, two declarations.

### H3. `*Layout` carries four incompatible meanings

| Type | Meaning |
|---|---|
| `NetworkGraphLayout`, `SankeyLayout` | an **algorithm** (enum namespace of pure functions) |
| `ThoughtGraphLayoutEngine` | an **algorithm** — but suffixed `Engine`, not `Layout` |
| `ThoughtGraphLayout` | the **per-node result**: "computed position and size" (`Models/ThoughtGraphNode.swift:320`) |
| `DashboardLayout` | the **user's saved arrangement** of panels (`Models/DashboardLayout.swift:7`) |
| `FlowLayout`, `ChipFlowLayout` | a SwiftUI **`Layout` protocol** conformance |
| `FilePreviewLayout` | geometry constants |

So `ThoughtGraphLayoutEngine` produces `ThoughtGraphLayout` values, while
`SankeyLayout` *is* the engine. Reading `SomethingLayout` tells you nothing.

**Recommendation.** Fix the two that actively mislead, leave the SwiftUI
conformances alone (that name is imposed by the framework):
- `ThoughtGraphLayout` → `ThoughtGraphNodeFrame` (it is one node's frame)
- `NetworkGraphLayout` → `NetworkGraphLayoutEngine`, `SankeyLayout` →
  `SankeyLayoutEngine` (aligning with `ThoughtGraphLayoutEngine`, which already
  has the right suffix)
- Adopt the rule: `*LayoutEngine` computes, `*Layout` is a persisted arrangement,
  `*Frame` is a computed geometry result.

### H4. "Event" spans two unrelated domains

- **Stream frame**: `GatewayEvent` ("all gateway event types the server can
  emit", `Models/GatewayEvent.swift:3`), `RawSessionEvent` ("one raw wire event…
  a snapshot of an SSE frame", `Services/RawEventLog.swift:5`),
  `SessionRunEvent`, `EventRecord`, `SessionTimelineEvent`, `*Payload`.
- **Wiki ingestion source**: `WikiTimelineEvent` ("one raw INPUT event that
  flowed into a knowledge base", `Models/WikiEventTimeline.swift:63`),
  `WikiEventRef`, `WikiEventChangesetRef`, `WikiEventKindStyle`, and the
  `type: event-type` taxonomy pages resolved by
  `WikiGraphViewModel+EventTypes.swift:3`.

Both senses also use "timeline" (`SessionTimelineEvent` vs `WikiTimelineEvent`)
and both have a "raw" variant (`RawSessionEvent` vs "a raw source file under
`raw/`"). `EventType` (`Models/WikiEventTypeRegistry.swift:33`) belongs to the
wiki sense but its unqualified name reads as the stream sense — and it sits next
to `Models/SessionTimelineEvent.swift`, which is the stream sense.

The wiki sense is not an event in the stream sense at all — it is a *trigger* or
*ingestion source*, which is exactly how its own doc describes it ("what a
trigger MEANS").

A separate case: **`SessionRunEvent` is not an event at all.** It is a persisted,
`Codable`, id-keyed record of one completed run (`Models/SessionRunEvent.swift:6`,
whose own logger category is `SessionRunEventStore`, persisted via
`SessionRunHistoryStore`) with a nested `RunStatus` of
`running/completed/failed/canceled`. By the codebase's own convention that is a
`*Record` — compare `CronRunRecord`, whose doc calls itself "a persisted snapshot
of a finished…".

**Recommendation.** Reserve `*Event` for backend stream frames.
- Rename the wiki family to the word its docs already use: `WikiTimelineEvent` →
  `WikiIngestion` (or `WikiTrigger`), `WikiEventRef` → `WikiIngestionRef`,
  `WikiEventKindStyle` → `WikiIngestionKindStyle`,
  `WikiEventTypeRegistry.EventType` → `IngestionKind`.
- Rename `SessionRunEvent` → `SessionRunRecord`, aligning it with `CronRunRecord`
  and `DelegationBatchRecord`.

### H5. "Model" carries four meanings

1. The **LLM** — `ModelCatalog`, `ModelPickerMenu`, `currentModel`, `AgentModel`.
2. An **ensemble artifact block** — `ModelSpec`: "named ENTITY SETS, RELATIONS…
   and stacked VIEWS" (`Models/ModelSpec.swift:3`). Nothing to do with LLMs.
3. A **3-D scene** — `Model3DSpec` (**undocumented**).
4. The **MVVM layer** — 16 `*ViewModel` types, plus `InAppBrowserModel`
   (a view model that dropped the suffix).

Sense 2 is the dangerous one: `ModelSpec` sitting next to `ModelCatalog` in
`Models/` reads as "the spec for a model" when it means "an ensemble data model
the agent emitted".

**Recommendation.** Rename `ModelSpec` → `EnsembleSpec` (its own doc calls it
"the ensemble artifact") and `Model3DSpec` → `Scene3DSpec`. Rename
`InAppBrowserModel` → `InAppBrowserViewModel` to stop leaking a fourth sense.
Leave the LLM sense unqualified — it is the dominant one.

### H6. `Theme` vs `AppTheme` are backwards

`AppTheme` (`Views/Theme.swift:11`) is a `Codable` **preset record** — one of five
palettes (`.midnight`, `.cosmic`, …) carrying hex strings.
`Theme` (`Views/Theme.swift:401`) is the **static facade** over
`ThemeManager.shared.colors` — the thing ~1,560 call sites actually read.

So the more specific-sounding name is the plain data and the generic name is the
API. `AppTheme` also carries non-color geometry — `bubbleRadius`, `bubblePaddingH`,
`bubblePaddingV`, `pillRadius`, `pillSpacing` (`Views/Theme.swift:184-188`) — under
the comment "Dimensions are shared — not theme-dependent." They are `static let`s
on a per-preset type that the code itself says are not per-preset, and the type's
doc ("a complete color palette") does not cover them.
Sub-themes `ButtonTheme`, `ToolbarIconTheme`, `AppFontTheme` are yet another axis
(component-scoped styling, not palettes).

**Recommendation.** Low-risk, mechanical:
- `AppTheme` → `ThemePreset` (small blast radius — presets are referenced from
  `ThemeManager` and the settings picker)
- Keep `Theme` as the facade; do **not** rename the 1,560-call-site name
- Move `AppTheme.pillRadius` and friends to a `Metrics`/`Geometry` namespace, or
  update the doc to say the type carries geometry as well as color
- Rename the component themes to `*Style` (`ButtonTheme` → `ButtonStyleTokens`)
  so "theme" means palette and nothing else

### H7. `*State` means both "value snapshot" and "observable object"

23 `*State` types split two ways:
- **Value snapshots** (`struct`/`enum`, Codable): `SRSState`, `QuizState`,
  `SessionRunState`, `DiffState`, `DownloadState`, `AvatarState`,
  `ConnectionState`, `Physics2DParams` (…which broke the suffix).
- **Observable filter objects** (`ObservableObject` classes): `CronFilterState`,
  `SessionsFilterState`, `SkillsFilterState`, `LaunchPaneState`.

`MouseState` is declared **four** times, once per graph surface —
`Views/CronInterflowGraphView.swift:261`, `Views/Wiki/WikiGraph2DCanvas.swift:126`,
`Views/Diagram/DiagramExplorerView.swift:86`,
`Views/ThoughtGraph/ThoughtGraphView.swift:154` — plus a fifth copy renamed
`IosMouseState` in the same file at L1650, with the identical
`case idle, deciding, panning`. All five are `private`, which is why the
duplication has survived.

**Recommendation.** Two rules, applied going forward and to the five copies now:
- `*State` = an immutable/Codable value. Observable classes get `*Store` or
  `*Filters` (`CronFilterState` → `CronFilters`).
- Extract one `GraphMouseState` into `Views/` and delete the five copies. This is
  a true merge — the case sets are identical. Note `GraphMouseInterceptor` /
  `GraphMouseView` are currently wiki-local
  (`Views/Wiki/WikiGraph2DCanvas.swift:82`) despite generic names; hoisting them
  alongside the shared enum is the natural companion change.

### H8. Parallel enums duplicated across the three `*FilterState` classes

`SortOrder` (×3), `FilterStatus` (×2), `TimeWindow` (×2), `DisplayMode` (×2) are
each declared independently inside `CronFilterState`
(`ViewModels/CronFilterState.swift`), `SessionsFilterState`
(`Views/MissionControl/SessionsFilterState.swift`) and `SkillsFilterState`
(`Views/Skills/SkillsFilterState.swift`).

This one is *documented as intentional*: `CronFilterState` says it mirrors
`SessionsFilterState` "so a cron reads like a specialized session… Cron-specific
dimensions… stand in for a session's live/ended status". The nesting keeps the
cases domain-appropriate, which is right.

But `TimeWindow` is genuinely identical in intent both times — `CronFilterState`'s
is "'Last run on or after' window, matched against a job's `lastRunAt`",
Sessions' is the same predicate against `lastActive`.

**Recommendation.** Keep `FilterStatus`/`SortOrder`/`DisplayMode` nested — the
cases really are per-domain. Extract only `TimeWindow` into
`Models/TimeWindow.swift` as a shared `Codable` enum parameterized on the date it
matches. Note the three classes also live in three different directories
(`ViewModels/`, `Views/MissionControl/`, `Views/Skills/`) despite being the same
kind of object — consolidate to `ViewModels/`.

---

## §S — Synonyms (several names, one concept)

### S1. Session identity: 13 names for 2 concepts

Reference counts across `Sources/`:

| Concept | Names in use |
|---|---|
| Stable / database ID | `sessionID` (557), `displayID` (148), `currentSessionID` (40), `sourceSessionID` (28), `id` |
| Runtime / gateway short-hex ID | `runtimeID` (75), `gatewayID` (57), `activeSessionID` (52), `sessionKey` (20), `rpcID` (13), `thread_key` (9, Centaur), `gwID` (4), `key` |

`SessionListViewModel`'s doc names the problem — it "tracks the mapping between
database IDs (from session.list) and gateway in-memory IDs (short hex, from
session.create) so RPCs work" — and the bridge helpers
(`stableSessionByGatewayID`, `gatewayIDByStableSession`,
`bindRuntimeSession(displayID:runtimeID:)`) prove the two-concept model is
understood.

The worst offender is bare `sessionID`, which appears on both sides: it is the
stable ID in `ChatViewModel.sessionStates`, the runtime ID in
`AgentBackend.activeSessionID`, and either one in `applyStreamingSessions`.
`resumeSession(key:)` takes the *stable* ID despite `key` elsewhere meaning
runtime. This ambiguity has already produced live bugs — the sidebar's
`isCurrent(_:)` had to be taught to match *either* form, and
`applyStreamingSessions` reconciles against both.

**Recommendation.** Adopt two words and enforce them:
- **`displayID`** — the stable/database ID. Retire `sessionID`, `sessionKey`, `key`.
- **`runtimeID`** — the gateway short-hex ID. Retire `gatewayID`, `rpcID`, `gwID`;
  keep `thread_key` only inside `CentaurClient`'s wire encoding.

Never use bare `sessionID` in a new signature. A `SessionID`/`RuntimeID` pair of
single-field `RawRepresentable` wrappers would make the two unmixable at compile
time and is worth the churn given the bug history — but the rename alone
captures most of the value.

### S2. Live / streaming / running / active

`SessionRunState`'s decoder normalizes the gateway's `streaming`, `active`,
`running` and `in_progress` to a single `.streaming` case — the codebase already
collapsing four server words into one. Portal-side, the same concept is called:
`isStreaming`, `streamingSessionIDs`, `SessionRunState.streaming`,
`localRunStates`, `RunStatus`, `SessionRunEvent`, and "live" throughout the doc
comments and UI copy ("a session's live/ended status", "lights up").

`SessionStatus` vs `SessionRunState` *is* a real distinction (alive-at-all vs
executing-now) and is documented well; the synonym problem is inside the second
one only.

Two overlapping status enums exist for the same axis:
`SessionRunState` (`Models/Session.swift:13` — `.streaming` and friends, the live
sidebar state) and `SessionRunEvent.RunStatus`
(`Models/SessionRunEvent.swift:18` — `running/completed/failed/canceled`, the
persisted record's outcome). Neither doc mentions the other, and `RunStatus` is
**undocumented**, so the relationship has to be inferred.

**Recommendation.** Pick `streaming` for code identifiers (it already dominates
and matches the wire) and "live" for user-facing copy. Then either express
`RunStatus` in terms of `SessionRunState` or document the split explicitly:
live-run state vs finished-run outcome is a legitimate distinction, but it has to
be stated to be readable.

### S3. Edge vs Link — same concept, split by neighbourhood

`ThoughtGraphEdge`, `CronGraphEdge`, `SkillGraphEdge`, bare `Edge` — versus
`WikiLink` ("a link between two wiki pages", `Models/WikiGraph.swift:29`), the
nested `Link` in `NetworkGraphSpec` and `SankeySpec`, and `ConceptLink`.

The wiki surface avoids "node" entirely — its node type is `WikiPage` — so
`WikiPage`/`WikiLink` is at least internally coherent. The block specs
(`NetworkGraphSpec`, `SankeySpec`) are the inconsistent pair: they use
`Node` + `Link`, mixing both vocabularies in one type.

There are also 9 unrelated `*Link` types (`GitHubLink`, `PortalDeepLink`,
`InAppBrowserLink`, `IntegrationLink`, `ExpandedLinkStatus`, `LinkifiedText`)
where "link" means *URL* — a third sense.

**Recommendation.** Standardize graph topology on **Node + Edge**; rename the
nested `Link` in `NetworkGraphSpec`/`SankeySpec` to `Edge` (both are private
nested types — near-zero blast radius). Leave `WikiPage`/`WikiLink` alone: it is
domain-correct wiki vocabulary and renaming it would fight the backend's own
`wiki.*` RPC names. Reserve unqualified "Link" for URLs.

### S4. `*Store` vs `*Cache` vs `*Manager` vs `*Service` have no boundary

14 `*Store`, 9 `*Service`, several `*Manager`, several `*Cache` — and no
documented rule separating them. Evidence they overlap:
- `SkillStore` and `SkillCache` are the same concept (§D1).
- `WikiGraphCache` is a `*Disk` sidecar by behaviour ("all disk access off the
  main actor") but named `*Cache`.
- `ThemeManager` "holds the active palette… persisted to UserDefaults" — which is
  exactly what `*Store` means elsewhere.
- `GatewayCapabilitiesStore` and `ActivityStore` are **undocumented**, so there is
  nothing to check them against.

`ArtifactStore`'s doc is the only place the pattern is spelled out: "three layers:
in-memory published dictionary (views observe) → disk (Application Support JSON) →
gateway".

**Recommendation.** Promote `ArtifactStore`'s three-layer description into
`docs/architecture-rules.md` as the definition of `*Store`, and fix the outliers:
`*Store` = observable collection + persistence; `*Cache` = pure disk sidecar with
no published state (rename to `*Disk` for consistency with `SkillStoreDisk`);
`*Manager` = singleton owning one global concern, no collection;
`*Service` = stateless capability wrapper. Then rename `ThemeManager` →
`ThemeStore` or accept it as a documented exception.

### S5. `*Kind` vs `*Status` vs `*Mode` are used interchangeably

17 `*Kind`, 8 `*Status`, 11 `*Mode`, and no distinction visible in usage.
`NodeStatus` (`Models/SpawnNode.swift:120` — a *spawn-tree* node) and
`ThoughtNodeStatus` (`Models/ThoughtGraphNode.swift:257` — a *thought-graph* node)
both answer "what phase is this node in", and the unqualified one is the narrower
concept. `DisplayMode`/`CanvasDisplayMode`/`ViewMode`/`LayoutMode` are all "which
rendering". Nine bare nested `enum Kind` declarations and four bare nested
`enum Mode` declarations make grep useless.

**Recommendation.** `*Kind` = what something *is* (immutable taxonomy);
`*Status`/`*State` = what phase it is *in* (changes over time);
`*Mode` = a user-selected presentation. Then:
- `NodeStatus` → `SpawnNodeStatus`, so it and `ThoughtNodeStatus` are both
  qualified. Compare the case sets before merging — they serve different node
  kinds and may legitimately differ.
- `ViewMode`/`DisplayMode`/`CanvasDisplayMode` should be qualified by surface, and
  the bare nested `Kind`/`Mode` enums renamed to name their owner.

---

## §D — Drift and regressions

### D1. `SkillCache` is fully documented and completely dead

`SkillCache` (`Services/SkillCache.swift:100`) carries a proper doc comment —
"shared skill cache that persists across navigations. Background-refreshes on a
timer and on demand; publishes diff-based updates" — and has **7 references, all
inside its own file**. Its only mention anywhere else in the repo is
`Tests/PortalTests/ArchitectureTests.swift:51`, where `SkillCache.swift` sits on
the SwiftUI-in-Services allowlist with a `TODO` to migrate it to Combine.

Meanwhile `SkillStore` (`Services/SkillStore.swift:189`) — the live one, 39
references, `@MainActor @Observable` — has **no doc comment at all**. Both have
disk sidecars (`SkillCacheDisk`, 4 refs, also file-local; `SkillStoreDisk`, 9 refs).

So the documentation describes the dead implementation and says nothing about the
live one, and the dead file is being maintained through the architecture-test
allowlist.

**Recommendation.** Delete `SkillCache.swift` (both `SkillCache` and
`SkillCacheDisk`), remove `"SkillCache.swift"` from the `ArchitectureTests`
allowlist and the matching `no_swiftui_in_services` exclusion in `.swiftlint.yml`
— the doc comment there says the two lists are "ONE SOURCE OF TRUTH… keep the two
in sync". Then move `SkillCache`'s doc comment onto `SkillStore`, amended to
describe what `SkillStore` actually does. Verify the disk formats first: if
`SkillCacheDisk`'s on-disk JSON is what shipped builds wrote, keep a one-time
migration read.

### D2. Undocumented types at the center of the domain

These carry no doc comment, which is why several collisions above were only
resolvable by reading implementations:

| Type | Site | Why it matters |
|---|---|---|
| `SkillStore` | `Services/SkillStore.swift:189` | the live skills source of truth (§D1) |
| `SessionRuntimeState` | `ViewModels/ChatViewModel.swift:342` | the per-session cache behind every session switch |
| `RunStatus` | — | indistinguishable from `SessionRunState` (§S2) |
| `SkillInfo` / `Skill` | `Models/Skill.swift:3` | 91 references |
| `ActivityItem`, `ActivityArtifact` | `Models/ActivityItem.swift` | the whole inbox domain |
| `GatewayCapabilitiesStore`, `ActivityStore` | `Services/` | `*Store` contract unverifiable (§S4) |
| `Harness`, `HarnessConfig` | — | the user-facing name for a backend |
| `Model3DSpec` | — | breaks the otherwise-perfect `*Spec` family |
| `CronGraph`, `FeedItem`, `ArtifactIntent`, `ReasoningTrace`, `Concept`, `DelegationStatus`, `EventRecord`, `SessionRunEvent`, `SessionTimelineEvent` | — | |

**Recommendation.** Document these nine highest-traffic ones before any rename
lands — the renames in §H and §S are only safe if the concepts are pinned down
first. `SessionRuntimeState` and `SkillStore` are the two that block the most
other work.

### D3. Doc/name drift, specific instances

- **`AppTheme`** — doc says "a complete color palette"; the type also carries
  geometry (`AppTheme.pillRadius`). Either move the geometry out or widen the doc.
  (§H6)
- **`ThoughtGraphLayout`** — the name promises the layout; the doc correctly says
  it is "layout information for a **single node**". Doc is right, name is wrong.
  (§H3)
- **`SessionRunState`** — doc says "the gateway may eventually return a precise
  `latest_run_state` field; until then Portal derives a conservative state". Worth
  re-checking against the current gateway: if the field now exists, the derivation
  is dead weight.
- **`GatewayClient` as a name** — the type is Hermes-specific, but Centaur's wiki
  adapter is written as `extension GatewayClient` (`Services/CentaurWikiClient.swift:34`)
  and Hermes Standard's chat "runs over the `/api/ws` sidecar via a plain
  `GatewayClient`" (`Services/HermesStandardClient.swift:158`). The name is now
  doing duty as "the WebSocket JSON-RPC client" across three backends. Either
  rename to `HermesGatewayClient` or state in its doc that it is the shared
  JSON-RPC transport, not the Hermes backend.

---

## Suggested order of work

Each step is independently landable and leaves the tree green.

1. **Document** the nine types in §D2. Nothing else is safe first. *(no behaviour change)*
2. **Delete** `SkillCache` + `SkillCacheDisk` and their two allowlist entries (§D1). *(pure removal)*
3. **Merge the true duplicates**: `SimNode` → shared `ForceNode` (§H2);
   `MouseState` ×4 → `GraphMouseState` (§H7); `TimeWindow` ×2 → shared (§H8).
   *(these are the only entries where two declarations describe one concept)*
4. **Rename the low-blast-radius misleaders**: nested `Link` → `Edge` in the two
   block specs (§S3); `ThoughtGraphLayout` → `ThoughtGraphNodeFrame` and
   `*Layout` → `*LayoutEngine` (§H3); `ModelSpec` → `EnsembleSpec`,
   `Model3DSpec` → `Scene3DSpec`, `InAppBrowserModel` → `InAppBrowserViewModel` (§H5).
5. **Write the suffix rules** into `docs/architecture-rules.md`: `*Store`/`*Cache`/
   `*Manager`/`*Service` (§S4), `*Kind`/`*Status`/`*Mode` (§S5), `*State` (§H7),
   `*Layout` (§H3). Rules first, then enforce on new code only.
6. **Session identity** (§S1) — the highest-value and highest-churn item. Do it
   last and as one mechanical pass: `displayID` / `runtimeID` everywhere, bare
   `sessionID` banned. Consider an `ArchitectureTests` check that no new
   declaration introduces `sessionID`.
7. **Artifact renames** (§H1) and **Wiki event renames** (§H4) — large but purely
   mechanical; land each as its own commit.
