# WikiGraphViewModel

The single state authority behind the wiki surface. It owns the graph data, the
force-directed layout simulation (2D `Canvas` + 3D SceneKit), the shared
page-selection plane, and the visibility of every attachment surface (reader,
file tree, timeline drawer, events page).

`@MainActor final class WikiGraphViewModel: ObservableObject` —
`Sources/Portal/ViewModels/WikiGraphViewModel.swift` (core + a `+Layout`
extension at the foot of the same file). One instance is created at
`ContentView.swift` and **shared** across both entry points: the macOS overlay
(`showWikiGraph`) and the iOS tab. The view (`WikiGraphView`) is a thin adaptive
shell over it — the graph *is* the wiki home; the reader/tree/timeline are
attachments.

## Responsibilities

1. **Load & cache the graph** from a `WikiSource` — the home Hermes gateway
   (`GatewayClient`) or an override Centaur `CentaurWikiClient`.
2. **Run the layout simulation** — seed nodes, pre-settle off-main, then a live
   30 Hz physics tick for drag/reheat.
3. **Hold the shared selection plane** — one "current page" that the reader,
   graph-node selection, file tree, and timeline all read and write, with
   back/forward history.
4. **Drive attachment-surface visibility** — reader (peek / fullscreen /
   compare), file tree, timeline drawer, and the full-surface events page.
5. **Filter & present** — search, taxonomy filtering, a backlink index, and
   per-type node color/radius.

## The source model

Loads are **source-generic**: both `GatewayClient` (Hermes) and
`CentaurWikiClient` (Centaur) conform to `WikiSource`, so `load(source:wiki:)`
handles both. The multi-wiki `wiki` selection is Hermes-only; other sources
ignore it.

`loadedSource` is held **strongly on purpose**. `ContentView` rebuilds its
override client on every `body` evaluation, so a weak ref would die between the
graph load and the first page read — the reader would then silently fall back to
the home gateway, which 404s every Centaur page. There is no retain cycle:
sources hold no view-model refs.

## Published state (surface bindings)

| Group | Properties |
|---|---|
| **Graph data** | `graph: WikiGraph` (didSet → `rebuildBacklinks()`), `simNodes`, `simLinks`, `isSettling` |
| **Selection plane** | `selectedPath`, `backStack`, `forwardStack`, `contentCache`, `failedPath`, `selectedNodeIndex`, `hoveredNodeIndex` |
| **Reader (macOS)** | `showPageDetail`, `readerFullscreen`, `readerWidth`, `pinnedPaths` (compare) |
| **Attachments** | `showFileTree`, `showTimeline`, `showEventsPage` |
| **Viewport** | `zoom`, `panOffset`, `is3D`; `canvasSize` (plain `var`, set by the canvas `GeometryReader`) |
| **Filter** | `searchQuery` (didSet), `selectedTaxonomyPath` (didSet), `availableWikis`, `selectedWikiPath` |
| **Status** | `isLoading`, `error` |

`selectedPage`, `selectedNodeTitle`, `taxonomyTree`, `comparePaths`,
`isComparing`, `canGoBack`, `canGoForward`, and `isFiltering` are derived
(computed), not stored.

## Key methods

- **`load(source:wiki:)`** — the one load seam. Bumps `loadGeneration`, paints
  the on-disk cache instantly on a cold open (home gateway only — override
  sources have no stable `cacheIdentity`), then `wikiScan` / `fetchGraph`, drops
  stale responses by generation, and refreshes the cache. `load(client:wiki:)`
  is a thin Hermes-typed wrapper.
- **`resetForGatewaySwitch()`** — clears the graph, nav stacks, and sim on a
  gateway switch, and bumps `loadGeneration` to drop any in-flight scan. Called
  from `ContentView.handleGatewaySwitch`. Without it, a stale graph from the old
  gateway both lingers on screen *and* blocks the empty-graph guards that gate
  reload — so the new gateway's wiki never loads.
- **`navigate(to:)` / `goBack()` / `goForward()` / `closePage()`** — the
  selection-plane history.
- **`ensureContentLoaded(client:path:)`** — the single page-body load seam.
  Routes to the source the graph loaded from (Centaur bodies never hit the home
  gateway) and fills `contentCache`; early-returns when already cached.
- **`selectNode(_:)` / `syncNodeSelection(toPath:)` / `centerOnNode(_:)`** —
  keep the graph node ↔ page path mirror in sync.
- **`setupSimulation()` → `setup2D` / `setup3D` → `finishSetup` →
  `settleAndReveal`** — the layout lifecycle.
- Reader / compare: `openReaderForSelection`, `toggleReaderFullscreen`,
  `setReaderWidth`, `pinCurrentPage`, `unpin`.

## Load lifecycle

The graph is warmed at connect and painted on open, not fetched on open:

1. **Connect** — `ContentView`'s `isConnected` handler calls `load(client:)`
   for the home gateway, guarded on an empty graph (no-op if the wiki is never
   opened, never re-fetches a live graph). This lands with `canvasSize == .zero`.
2. **First open** — `WikiGraphView.onAppear` finds `graph.pages` already
   populated and skips the fetch; the canvas measures its size and builds the
   sim. Only cold cases (prefetch still in flight, or it failed) fall through to
   load here.
3. **Recovery** — `onChange(of: isConnected)` retries `attemptInitialLoad` if
   the surface appeared before the socket connected (the first scan would have
   thrown `.notConnected`), guarded on an empty graph.

> Historically the graph only began fetching in `onAppear` despite a comment
> claiming eager loading — so every first open showed a blank "Loading…"
> surface for the length of the `wiki.scan` round-trip, then popped in. Fixed by
> actually warming at connect (PR #61).

## Invariants & guards

These matter for anyone changing the VM:

- **`canvasSize != .zero` gate.** `setupSimulation()` no-ops until the canvas
  reports a non-zero size; `load()` skips setup when the size is still zero and
  the canvas's `onAppear`/`onChange` builds it once measured
  (`WikiGraph2DCanvas.swift`). This is precisely why connect-time prefetch works:
  the graph can land with no canvas yet, and the sim is built when the canvas
  appears.
- **Generation counters everywhere.** `loadGeneration` (stale scans),
  `settleGeneration` (stale pre-settle), `physicsGeneration` (stale off-main
  frames). Any rebuild bumps the relevant counter; late async completions
  check-then-discard against it. **Any new async path that mutates `graph` or
  `simNodes` must bump `loadGeneration` / respect these checks**, or a slow
  response can overwrite a newer graph.
- **Off-main physics.** `stepPhysics2D` is a `nonisolated static` pure function
  over a `Sendable` `Physics2DParams` snapshot; the live tick (`tick2D`) and the
  pre-settle (`settleAndReveal`) share it so both produce identical layouts.
  Only the cheap position write-back and a single `@Published` publish happen on
  the main actor. `physicsInFlight` drops slow frames rather than queueing
  main-thread work. **Incident:** the O(n²) integration used to run
  synchronously on `@MainActor`, so dragging (which keeps `alpha` hot) saturated
  the same thread that handles input and redraws — the choppy-navigation
  regression on large graphs.
- **Cache scope.** The on-disk graph cache (`WikiGraphCache`) is **home-gateway
  only** (guarded `source as? GatewayClient`); override sources have no stable
  identity and always fetch live. The in-memory `contentCache` is per-source and
  cleared on any `prepareForLoad` / wiki switch.
- **`isSettling` withholds drawing** (~0.2s fade) so the graph appears
  already-relaxed rather than exploding apart on screen. This is the *intended*
  reveal animation — distinct from the blank-first-render bug above.

## Performance notes

- **`cachedRadii` is precomputed on degree change.** `nodeRadius(at:)` sits on
  the 30 fps draw path (every node, every frame); computing sqrt-normalized
  sizing there — with an `O(n)` `degrees.max()` inside — cost ~16M
  comparisons/sec on a 747-node graph and dragged the whole canvas.
- **Pre-settle is capped** at `min(300, max(60, n))` steps so large graphs never
  block perceptibly while relaxing off-main.
- Node radius scales with connectivity relative to the graph's hub
  (sqrt-normalized), matching the docs-site frontend's `size ∝ ingress+egress`.

## Layering

Sits at the ViewModel layer (see `docs/architecture-rules.md`): it orchestrates
services (`WikiSource` implementations, `WikiGraphCache`) and exposes observable
state; `WikiGraphView` and its sub-views render that state and never reach past
it to a client directly.
