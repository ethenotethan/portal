import SwiftUI
import Combine
import os
import simd

private let log = PortalLogger(category: "WikiGraphViewModel")

@MainActor
final class WikiGraphViewModel: ObservableObject {

    @Published var graph: WikiGraph = .empty {
        didSet { rebuildBacklinks(); rebuildNestedTypeColors(); rebuildGraphStats() }
    }

    // MARK: - Adaptive layout state
    // One surface: the graph is the wiki home. Everything else is an
    // attachment — the reader opens on selection, the file tree is a
    // toggleable sidebar, and the changeset timeline is a drawer.

    /// Reader visibility: true presents the reader for `selectedPath` over the
    /// always-alive graph — a right-docked panel on macOS, a sheet on iOS. One
    /// reader, driven by the shared selection plane (no per-card history).
    @Published var showPageDetail = false
    /// macOS: the docked reader fills over the whole graph. A pure toggle —
    /// Peek (docked beside the graph) ⇄ fullscreen (reader owns the surface).
    /// iOS presents a sheet, so this stays false there.
    @Published internal var readerFullscreen = false
    /// macOS: width of the right-docked reader panel, set by dragging its
    /// divider. Clamped by `setReaderWidth` against the live surface on drag.
    @Published internal var readerWidth: CGFloat = 460
    /// macOS Compare: additional pages pinned beside the active reader. The
    /// grid renders these plus the current `selectedPath`; empty = plain Peek.
    /// Read-only snapshots keyed by path — no per-tile history, unlike the
    /// retired floating cards.
    @Published internal private(set) var pinnedPaths: [String] = [] {
        didSet { rebuildGraphStats() }
    }
    /// Node, edge and structure counts for the graph on screen, recomputed when
    /// the graph or the pins change — never in a body (see GraphStats).
    @Published internal private(set) var graphStats = GraphStats.empty
    /// Folder-tree sidebar (macOS) / browse sheet (iOS) visibility.
    @Published var showFileTree = false
    /// Changeset-timeline drawer (macOS) / sheet (iOS) visibility.
    /// Harness-only; the hosting view hides the affordance for sources that
    /// don't conform to WikiChangesetSource.
    @Published var showTimeline = false
    /// Full-surface events page: while true the adaptive host swaps the graph
    /// surface for the events page (a page WITHIN the wiki, not an overlay).
    /// The toggle affordance gates on WikiEventLogSource conformance — both
    /// backends have an ingestion log — on the same plane as the graph.
    @Published var showEventsPage = false
    /// An event the events page should land on, by source key.
    ///
    /// Set by a changeset's provenance chip: "this change came from that event"
    /// is only half a link if you can't follow it. The events page consumes and
    /// clears it, widening its window when the event predates the current one —
    /// arriving at a feed that doesn't contain what you clicked would read as
    /// the event not existing.
    @Published internal var focusedEventKey: String?
    @Published var selectedNodeIndex: Int?
    /// Hover lives on the simulation store (it changes per mouse move);
    /// forwarded for callers that only hold the view model.
    internal var hoveredNodeIndex: Int? { simulation.hoveredNodeIndex }

    /// What the wiki says its ingestion sources ARE, built from its
    /// `type: event-type` pages. `.empty` until those pages are read (and
    /// legitimately forever, for a wiki that declares none) — every lookup
    /// still answers, deriving label and color from the wire kind, so no
    /// surface has to branch on whether the taxonomy has loaded.
    /// Written only by `loadEventTypes` (see WikiGraphViewModel+EventTypes).
    @Published internal var eventTypes: WikiEventTypeRegistry = .empty

    /// True while the 2D layout is being pre-settled off the main thread.
    /// The canvas withholds drawing until this clears, so the graph appears
    /// already relaxed and framed instead of animating apart on screen.
    @Published private(set) var isSettling = false

    // MARK: - Shared page selection plane
    // One "current page" across every surface: the reader, the graph's node
    // selection, the file-tree sidebar, and the timeline drawer all read and
    // write this.

    @Published var selectedPath: String?
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published private(set) var contentCache: [String: WikiPageContent] = [:]
    @Published var failedPath: String?
    private(set) var backlinkIndex: [String: [WikiPage]] = [:]

    var selectedPage: WikiPage? {
        guard let path = selectedPath else { return nil }
        return graph.pages.first { $0.path == path }
    }

    var selectedNodeTitle: String? {
        guard let idx = selectedNodeIndex, nodeMeta.indices.contains(idx) else { return nil }
        return nodeMeta[idx].label
    }
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchQuery = "" {
        didSet { updateFilteredNodes() }
    }

    /// Node indices that match the current search query OR taxonomy filter. Empty = show all.
    var filteredNodeIndices: Set<Int> = []
    private var cachedQuery: String = ""
    private var cachedTaxonomyPath: String?

    /// Whether filtering is active (search or taxonomy)
    var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || selectedTaxonomyPath != nil
    }

    /// Taxonomy tree built from the graph's tag_path values.
    var taxonomyTree: TaxonomyNode { graph.tagPathTree }

    private func updateFilteredNodes() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let tp = selectedTaxonomyPath
        guard cachedQuery != q || cachedTaxonomyPath != tp else { return }
        cachedQuery = q
        cachedTaxonomyPath = tp

        if q.isEmpty && tp == nil {
            filteredNodeIndices.removeAll()
            return
        }

        let terms = q.split(separator: " ").map(String.init)
        // One id→page index per query, not one per node (the old computed
        // lookup rebuilt a 5k-entry dictionary inside the filter closure).
        let pageIndex = indexLookup

        filteredNodeIndices = Set(nodeMeta.indices.filter { idx in
            let node = nodeMeta[idx]
            guard let pi = pageIndex[node.id], graph.pages.indices.contains(pi) else { return true }

            let page = graph.pages[pi]

            // Taxonomy filter: must have a tag_path matching the selected prefix
            if let tp = tp, !tp.isEmpty {
                let matches = page.tagPath.contains { $0.hasPrefix(tp) }
                if !matches { return false }
            }

            // Search filter: must match label or type
            if !terms.isEmpty {
                let haystack = "\(node.label.lowercased()) \(node.type.lowercased())"
                return terms.allSatisfy { haystack.contains($0) }
            }

            return true
        })
    }

    /// Maps node IDs to page indices for quick lookup
    private var indexLookup: [String: Int] {
        var lookup: [String: Int] = [:]
        for (i, page) in graph.pages.enumerated() {
            lookup[page.id] = i
        }
        return lookup
    }

    /// Node identity (id, label, path, type), index-aligned with the
    /// simulation store's position buffers. Published once per graph load —
    /// never per frame. See WikiSimNodeMeta.
    @Published internal private(set) var nodeMeta: [WikiSimNodeMeta] = []
    /// id → node index, so selection sync doesn't scan 5k nodes.
    internal private(set) var nodeIndexByID: [String: Int] = [:]
    /// Everything that changes per frame or per mouse move: positions,
    /// velocities, painter's order, hover, camera, the physics clock. Only the
    /// canvases observe it; this object never publishes on a frame.
    internal let simulation = WikiSimulationStore()

    @Published var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []
    /// Per-edge relationship label, aligned 1:1 with `simLinks` (built in the
    /// same pass). `nil` = a plain, untyped wikilink with nothing to render.
    @Published internal private(set) var simLinkLabels: [String?] = []
    /// Node indices sorted by Y (painter's order for the 2D canvas); owned by
    /// the simulation store, forwarded for callers holding the view model.
    internal var drawOrder: [Int] { simulation.drawOrder }
    private(set) var degrees: [Int] = []
    private(set) var adjacency: [Set<Int>] = []

    internal var simAlpha: CGFloat { simulation.alpha }
    /// 2D canvas vs 3D SceneKit rendering of the same graph — a toggle in
    /// the graph controls, not a separate top-level mode.
    @Published var is3D = false

    /// Camera state forwarded from the simulation store (it changes per
    /// gesture event; observers that only need it on change subscribe to
    /// `simulation.$zoom`).
    internal var zoom: CGFloat {
        get { simulation.zoom }
        set { simulation.zoom = newValue }
    }
    internal var panOffset: CGSize {
        get { simulation.panOffset }
        set { simulation.panOffset = newValue }
    }
    internal var canvasSize: CGSize {
        get { simulation.canvasSize }
        set { simulation.canvasSize = newValue }
    }

    /// Per-graph color for each folder branch (e.g. "entities/chain"), rebuilt
    /// whenever `graph` changes. Every branch present in the graph gets its own
    /// hue so no two families collide; empty when no page lives in a folder.
    /// Rebuilt in `rebuildNestedTypeColors` (WikiGraphViewModel+TypeColors).
    internal var nestedTypeColors: [String: Color] = [:]

    /// The fill for a graph node: its folder-branch hue when the page sits in a
    /// colored folder, else the flat-type palette below.
    ///
    /// The graph colors by folder because that's where a real compendium's
    /// hierarchy lives — every `type` is flat ("org", "chain", "meta") while the
    /// nesting is entirely in the path ("entities/chain/base.md"). Keying color
    /// off `type` left ~all nodes grey; keying off the path folder groups them.
    internal func color(forNode node: WikiSimNodeMeta) -> Color {
        if let branch = Self.branchKey(for: node.path), let color = nestedTypeColors[branch] {
            return color
        }
        return color(for: node.type)
    }

    func color(for type: String) -> Color {
        switch type {
        case "entity": return Color(hex: "7c7cff") ?? .purple
        case "concept", "topic": return Color(hex: "5cb85c") ?? .green
        case "comparison": return Color(hex: "e8a838") ?? .orange
        case "query": return Color(hex: "ff6b9d") ?? .pink
        case "raw": return Color(hex: "888888") ?? .gray
        case "meta", "index", "log": return Color(hex: "5ad4e6") ?? .cyan  // root pages (index.md, log.md)
        // Additional page kinds beyond the core set.
        case "glossary": return Color(hex: "5ad4e6") ?? .cyan   // taxonomy definitions
        case "project": return Color(hex: "e8a838") ?? .orange
        case "goal": return Color(hex: "ff6b9d") ?? .pink
        // Code-graph kinds (CodeGraphSource). Distinct hues, no wiki type
        // collides; modules are the hub hue, externals muted.
        case "module": return Color(hex: "4a9eff") ?? .blue
        case "class": return Color(hex: "c678dd") ?? .purple
        case "func": return Color(hex: "56d364") ?? .green
        case "symbol": return Color(hex: "d19a66") ?? .orange
        case "external": return Color(hex: "6a6a6a") ?? .gray
        default: return Color(hex: "aaaaaa") ?? .gray
        }
    }


    /// Per-node radii, PRECOMPUTED when degrees change. nodeRadius(at:) is
    /// on the Canvas draw path (every node, every frame at 30fps); computing
    /// sqrt-normalized sizing there — with an O(n) degrees.max() inside —
    /// cost ~16M comparisons/sec on a 747-node graph and dragged the whole
    /// canvas (the choppy-navigation regression).
    private var cachedRadii: [CGFloat] = []

    /// Node radius scales with connectivity RELATIVE to the graph's hub —
    /// sqrt-normalized so a degree-248 hub visibly dwarfs a degree-6 median
    /// node (the old log-with-cap formula rendered them near-identical),
    /// while sqrt keeps mid-degree nodes distinguishable instead of letting
    /// one hub flatten everything else. Matches the docs-site frontend's
    /// presentation (size ∝ ingress+egress).
    func recomputeRadii() {
        let maxDegree = degrees.max() ?? 0
        cachedRadii = nodeMeta.indices.map { index in
            let base = nodeRadius(for: nodeMeta[index].type)
            let degree = degrees.indices.contains(index) ? degrees[index] : 0
            guard maxDegree > 0, degree > 0 else { return base }
            return base + sqrt(CGFloat(degree) / CGFloat(maxDegree)) * 16
        }
    }

    func nodeRadius(at index: Int) -> CGFloat {
        cachedRadii.indices.contains(index) ? cachedRadii[index] : 5
    }

    @Published var selectedWikiPath: String?
    @Published var availableWikis: [String] = []

    /// Currently selected taxonomy path for hierarchical filtering.
    /// When set, only nodes whose tag_path starts with this prefix are shown.
    @Published var selectedTaxonomyPath: String? {
        didSet { updateFilteredNodes() }
    }

    internal var loadGeneration = 0
    /// Invalidates wiki.list responses when the active gateway changes so a
    /// slower old gateway cannot repopulate aliases after reset.
    internal var wikiDiscoveryGeneration = 0
    internal func isCurrentWikiDiscovery(_ generation: Int) -> Bool { generation == wikiDiscoveryGeneration }
    /// Read-only view of the load counter for extensions that run async work
    /// against a load and must drop out when a newer one supersedes it.
    internal var currentLoadGeneration: Int { loadGeneration }
    private var loadedWiki: String?
    private var hasLoadedOnce = false

    /// On-disk cache of the last-known graph. On a cold open we paint the
    /// cached graph instantly (so the surface isn't blank behind a "Loading…"
    /// overlay while the serial wiki.list → wiki.scan round-trips complete),
    /// then replace it with the fresh scan. Injectable so tests use a scratch
    /// dir. Only the home gateway (GatewayClient) has a stable cacheIdentity;
    /// override sources (CodeGraphSource) skip the cache.
    private let graphCache: WikiGraphCache

    internal init(graphCache: WikiGraphCache = WikiGraphCache()) {
        self.graphCache = graphCache
    }
    /// The source the current graph was loaded from; the reader fetches page
    /// bodies through it so override wikis (CodeGraphSource) don't hit the home
    /// gateway. Strong on purpose: ContentView rebuilds its override client on
    /// every body evaluation, so a weak ref here dies between graph load and
    /// page read and the reader silently falls back to the home gateway (which
    /// 404s every code-graph page). No cycle: sources hold no view-model refs.
    private var loadedSource: (any WikiSource)?

    internal func load(client: GatewayClient, wiki: String? = nil, generation: Int? = nil) async {
        await load(source: client, wiki: wiki, generation: generation)
    }

    /// Source-generic load: the harness (GatewayClient) and CodeGraphSource
    /// conform to WikiSource. `wiki` selection is harness-only (multi-wiki
    /// gateways); other sources ignore it.
    internal func load(source: any WikiSource, wiki: String? = nil, generation: Int? = nil) async {
        let generation = generation ?? beginLoad(wiki: wiki)
        // A named selection establishes its generation synchronously in the
        // button action. If this task was scheduled after a newer click, drop
        // it before it can mutate source, graph, or loading state.
        guard generation == loadGeneration else { return }
        loadedSource = source
        defer { if generation == loadGeneration { isLoading = false } }

        // Cold-open fast path: paint the last-known graph immediately so the
        // surface isn't blank behind the "Loading…" overlay while the scan
        // runs. Home gateway only — override sources have no stable identity.
        // Skipped once we already have data on screen (warm revisit / retry).
        let gateway = source as? GatewayClient
        if let gateway, graph.pages.isEmpty {
            let identity = gateway.cacheIdentity
            if let cached = await graphCache.load(identity: identity, wiki: wiki) {
                guard generation == loadGeneration else { return }
                // Don't clobber a fresh graph that landed while we read disk.
                if graph.pages.isEmpty {
                    self.graph = cached
                    // Settle in the background even before the surface exists
                    // (canvasSize == .zero → nominal fallback), so the first
                    // open paints a framed graph.
                    setupSimulation()
                }
            }
        }

        do {
            let newGraph: WikiGraph
            if let gateway {
                newGraph = try await gateway.wikiScan(wiki: wiki)
            } else {
                newGraph = try await source.fetchGraph()
            }
            // Drop stale responses if a newer load was started meanwhile.
            guard generation == loadGeneration else { return }
            self.graph = newGraph
            setupSimulation()
            // Refresh the cache with the fresh scan (home gateway only).
            if let gateway {
                graphCache.store(newGraph, identity: gateway.cacheIdentity, wiki: wiki)
            }
            // Resolve the wiki's event-type taxonomy off the graph we just
            // loaded. The loading state is dropped FIRST: definition pages are
            // extra round-trips, and holding the overlay up for them would
            // regress the cold-open latency work for a taxonomy that every
            // surface can already answer from its derived fallback.
            isLoading = false
            await loadEventTypes(source: source)
        } catch {
            guard generation == loadGeneration else { return }
            log.error("wiki.scan failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func loadPage(client: GatewayClient, path: String, wiki: String? = nil) async -> WikiPageContent? {
        do { return try await client.wikiPage(path: path, wiki: wiki) }
        catch { log.error("wiki.page failed: \(error.localizedDescription)"); return nil }
    }

    // MARK: - Shared navigation (history + content cache)

    /// Selection and history are wiki-scoped: switching wikis invalidates
    /// paths, cache, and stacks. Any reload drops the content cache so the
    /// reader picks up fresh page bodies. Internal for tests.
    func prepareForLoad(wiki: String?) {
        contentCache.removeAll()
        if hasLoadedOnce && wiki != loadedWiki {
            clearPageSelection()
        }
        loadedWiki = wiki
        hasLoadedOnce = true
    }

    func clearPageSelection() {
        selectedPath = nil
        backStack.removeAll()
        forwardStack.removeAll()
        contentCache.removeAll()
        failedPath = nil
        showPageDetail = false
        readerFullscreen = false
        pinnedPaths.removeAll()
        selectedNodeIndex = nil
        // Wiki switch: the events surface belongs to the previous source.
        showEventsPage = false
    }

    /// Drop the graph and all navigation state on a gateway switch. The graph
    /// belongs to the previous gateway; without this the stale graph both stays
    /// on screen and blocks the connect-time prefetch / onAppear reload (both
    /// guard on an empty graph), so the new gateway's wiki would never load.
    /// Bumps the generation so any in-flight scan for the old gateway is dropped.
    internal func resetForGatewaySwitch() {
        loadGeneration += 1
        wikiDiscoveryGeneration += 1
        graph = .empty
        nodeMeta = []
        nodeIndexByID = [:]
        simulation.clear()
        loadedSource = nil
        loadedWiki = nil
        hasLoadedOnce = false
        availableWikis = []
        selectedWikiPath = nil
        isLoading = false
        error = nil
        // The taxonomy is the previous wiki's declaration, not a global.
        eventTypes = .empty
        clearPageSelection()
    }

    /// Navigates the shared reader to a page, pushing the current page onto
    /// the back stack. Also mirrors the selection into the graph node.
    func navigate(to path: String) {
        guard path != selectedPath else { return }
        if let current = selectedPath { backStack.append(current) }
        forwardStack.removeAll()
        select(path)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selectedPath { forwardStack.append(current) }
        select(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selectedPath { backStack.append(current) }
        select(next)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func closePage() {
        selectedPath = nil
        backStack.removeAll()
        forwardStack.removeAll()
        showPageDetail = false
        readerFullscreen = false
        pinnedPaths.removeAll()
        selectedNodeIndex = nil
    }

    private func select(_ path: String) {
        selectedPath = path
        if failedPath == path { failedPath = nil }
        syncNodeSelection(toPath: path)
    }

    func cachedContent(for path: String) -> WikiPageContent? { contentCache[path] }

    func storeContent(_ content: WikiPageContent?, for path: String) {
        if let content {
            contentCache[path] = content
            if failedPath == path { failedPath = nil }
        } else if selectedPath == path {
            failedPath = path
        }
    }

    /// Single load seam for every reader surface: fetches from the same
    /// source the graph loaded from (the selected wiki) and fills the cache.
    func ensureContentLoaded(client: GatewayClient, path: String) async {
        guard contentCache[path] == nil else { return }
        let content: WikiPageContent?
        if let source = loadedSource, !(source is GatewayClient) {
            // Override wiki (CodeGraphSource): page bodies come from the same
            // source the graph did, never the home gateway.
            content = await loadPage(source: source, path: path)
        } else {
            content = await loadPage(client: client, path: path, wiki: loadedWiki)
        }
        storeContent(content, for: path)
    }

    // MARK: - Selection sync (graph node <-> page path)

    /// Mirrors a page selection into the corresponding sim node, if the page
    /// exists in the loaded graph.
    func syncNodeSelection(toPath path: String?) {
        guard let path,
              let page = graph.pages.first(where: { $0.path == path }),
              let idx = nodeIndexByID[page.id] else {
            selectedNodeIndex = nil
            return
        }
        selectedNodeIndex = idx
    }

    /// Selects the graph node AND makes its page the shared current page,
    /// pushing the previous page onto the reader's back stack.
    func selectNode(_ index: Int) {
        guard nodeMeta.indices.contains(index) else { return }
        selectedNodeIndex = index
        if let page = graph.pages.first(where: { $0.id == nodeMeta[index].id }) {
            navigate(to: page.path)
        }
    }

    /// Centers the 2D viewport on a node at the current zoom.
    func centerOnNode(_ index: Int) {
        guard simulation.positions.indices.contains(index), canvasSize != .zero else { return }
        let pos = simulation.positions[index]
        panOffset = CGSize(
            width: canvasSize.width / 2 - pos.x * zoom,
            height: canvasSize.height / 2 - pos.y * zoom
        )
    }

    /// Opens the reader for the currently selected page: a right-docked panel
    /// on macOS, the reader sheet on iOS. Every "jump into a page" path funnels
    /// through here, so the two platforms diverge in exactly one place.
    func openReaderForSelection() {
        guard selectedPath != nil else { return }
        showPageDetail = true
    }

    // MARK: - Docked reader (macOS)

    /// Peek ⇄ fullscreen. Inert when no page is open, so the toggle can't strand
    /// the surface on a fullscreen blank.
    internal func toggleReaderFullscreen() {
        guard showPageDetail, selectedPath != nil else { return }
        readerFullscreen.toggle()
    }

    /// Clamp the docked reader width to the surface as the divider drags. The
    /// panel never eats more than ~70% of the width or shrinks below its floor.
    internal func setReaderWidth(_ width: CGFloat, surfaceWidth: CGFloat) {
        let maxWidth = max(Self.minReaderWidth, surfaceWidth * 0.7)
        readerWidth = min(max(Self.minReaderWidth, width), maxWidth)
    }

    internal static let minReaderWidth: CGFloat = 320

    // MARK: - Compare (macOS)

    /// Pages shown together in the reader: the active page first, then every
    /// pinned page (de-duplicated). One entry = plain Peek; more = the grid.
    internal var comparePaths: [String] {
        guard let active = selectedPath else { return pinnedPaths }
        return [active] + pinnedPaths.filter { $0 != active }
    }

    internal var isComparing: Bool { comparePaths.count > 1 }
    internal func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }

    /// Pin the current page so opening another keeps it on-screen for
    /// side-by-side reading. No-op if there's nothing selected or it's already
    /// pinned.
    internal func pinCurrentPage() {
        guard let path = selectedPath, !pinnedPaths.contains(path) else { return }
        pinnedPaths.append(path)
    }

    internal func unpin(_ path: String) {
        pinnedPaths.removeAll { $0 == path }
    }

    internal func clearComparison() {
        pinnedPaths.removeAll()
    }

    // MARK: - Cross-surface affordances

    /// "Show in Graph": close the reader and reveal the current page's node
    /// selected and centered on the 2D canvas.
    func showCurrentPageInGraph() {
        showPageDetail = false
        readerFullscreen = false
        if is3D { is3D = false; setupSimulation() }
        syncNodeSelection(toPath: selectedPath)
        if let idx = selectedNodeIndex { centerOnNode(idx) }
    }

    /// Flips the 2D canvas / 3D SceneKit rendering, reseeding the simulation
    /// and carrying the shared page selection into the fresh node set.
    func setRendering3D(_ enabled: Bool) {
        guard is3D != enabled else { return }
        is3D = enabled
        setupSimulation()
        if !enabled, let idx = selectedNodeIndex { centerOnNode(idx) }
    }

    /// "Reveal in sidebar": open the file tree with the page selected.
    func revealInFileTree(path: String) {
        showFileTree = true
        navigate(to: path)
    }


    private func rebuildGraphStats() {
        graphStats = .wiki(graph, pinnedCount: pinnedPaths.count)
    }
    private func rebuildBacklinks() {
        let byId = Dictionary(graph.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var index: [String: [WikiPage]] = [:]
        var seen: [String: Set<String>] = [:]
        for link in graph.links {
            guard let source = byId[link.source] else { continue }
            if seen[link.target, default: []].insert(source.id).inserted {
                index[link.target, default: []].append(source)
            }
        }
        for key in index.keys {
            index[key]?.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        backlinkIndex = index
    }

    func backlinks(for page: WikiPage?) -> [WikiPage] {
        page.flatMap { backlinkIndex[$0.id] } ?? []
    }

    func loadPage(source: any WikiSource, path: String) async -> WikiPageContent? {
        do { return try await source.fetchPage(path: path) }
        catch { log.error("wiki page fetch failed: \(error.localizedDescription)"); return nil }
    }

    func setupSimulation() {
        guard !graph.pages.isEmpty else { return }
        if is3D { setup3D() } else { setup2D() }
    }

    /// True when the current layout was settled against the nominal size
    /// (never displayed yet). The canvas clears this via
    /// `refitForFirstDisplayIfNeeded` on its first real frame.
    internal private(set) var settledAgainstNominalSize = false

    private func setup2D() {
        let center = CGPoint(x: effectiveCanvasSize.width / 2, y: effectiveCanvasSize.height / 2)
        var rng = SystemRandomNumberGenerator()
        // Seed radius grows with √n past 200 so a 5k-node wiki doesn't start as
        // one impenetrable blob; small graphs keep the old 50…200 ring.
        let spread = max(200, 20 * Double(graph.pages.count).squareRoot())
        let seeded: [CGPoint] = graph.pages.map { _ in
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 50...spread, using: &rng)
            return CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist)
        }
        finishSetup(positions: seeded, positions3D: nil)
        if presettleEnabled { settleAndReveal() }
    }

    /// Tests that need a deterministic layout adopt positions directly and
    /// switch the off-main pre-settle off; the app never touches this.
    internal var presettleEnabled = true

    private func setup3D() {
        var rng = SystemRandomNumberGenerator()
        // Seed radius grows with cbrt(n) so node density stays roughly constant.
        let spread = Float(cbrt(Double(max(graph.pages.count, 1)))) * Self.seedSpacing3D
        let seeded: [SIMD3<Float>] = graph.pages.map { _ in
            let phi = Float.random(in: 0...(2 * .pi), using: &rng)
            let theta = Float.random(in: (-Float.pi / 2)...(Float.pi / 2), using: &rng)
            let r = Float.random(in: (spread * 0.4)...spread, using: &rng)
            return SIMD3(r * cos(theta) * cos(phi), r * cos(theta) * sin(phi), r * sin(theta))
        }
        finishSetup(positions: nil, positions3D: seeded)
    }

    private static let seedSpacing3D: Float = 50

    /// Build identity, links, degrees and adjacency for the page set (first
    /// occurrence of a duplicate id wins), then hand the seeded buffers to the
    /// simulation store. `positions`/`positions3D` are index-aligned with
    /// `graph.pages`; whichever is nil is filled with zeros.
    private func finishSetup(positions: [CGPoint]?, positions3D: [SIMD3<Float>]?) {
        var seenIds = Set<String>()
        var meta: [WikiSimNodeMeta] = []
        var kept2D: [CGPoint] = []
        var kept3D: [SIMD3<Float>] = []
        for (offset, page) in graph.pages.enumerated() where seenIds.insert(page.id).inserted {
            meta.append(WikiSimNodeMeta(id: page.id, type: page.type, label: page.title, path: page.path))
            kept2D.append(positions?[offset] ?? .zero)
            kept3D.append(positions3D?[offset] ?? .zero)
        }
        nodeIndexByID = Dictionary(uniqueKeysWithValues: meta.enumerated().map { ($1.id, $0) })
        let idToIndex = nodeIndexByID
        let resolved: [(edge: (sourceIndex: Int, targetIndex: Int), label: String?)] = graph.links.compactMap { link in
            guard let si = idToIndex[link.source], let ti = idToIndex[link.target] else { return nil }
            return ((si, ti), link.displayRelation)
        }
        let links = resolved.map(\.edge)
        degrees = Array(repeating: 0, count: meta.count)
        adjacency = Array(repeating: Set<Int>(), count: meta.count)
        for (si, ti) in links {
            if degrees.indices.contains(si) { degrees[si] += 1; adjacency[si].insert(ti) }
            if degrees.indices.contains(ti) { degrees[ti] += 1; adjacency[ti].insert(si) }
        }
        nodeMeta = meta
        simLinks = links
        simLinkLabels = resolved.map(\.label)
        recomputeRadii()
        // Rebuilding invalidates any physics frame or settle still computing
        // against the old node set; the store bumps its generations.
        simulation.reset(positions: kept2D, positions3D: kept3D, links: links, adjacency: adjacency, is3D: is3D)
        updateFilteredNodes()
        // Rebuilding invalidates node indices; carry the shared page
        // selection back into the fresh sim so mode switches keep context.
        syncNodeSelection(toPath: selectedPath)
    }

    /// One frame of the simulation clock. The store only advances when there
    /// is something to integrate (see `WikiSimulationStore.shouldTick`); the
    /// pre-settle owns the graph while `isSettling`.
    internal func tick() {
        guard !isSettling else { return }
        simulation.tick()
    }

    internal func startDragging(index: Int, at point: CGPoint) {
        simulation.startDragging(index: index)
    }

    internal func dragNode(index: Int, to point: CGPoint) {
        let mx = (point.x - panOffset.width) / zoom
        let my = (point.y - panOffset.height) / zoom
        simulation.dragNode(index: index, to: CGPoint(x: mx, y: my))
    }

    internal func stopDragging(index: Int) { simulation.stopDragging(index: index) }

    internal func updateHover(at point: CGPoint) {
        noteInteraction()
        simulation.setHover(hitTest(point: point))
    }
    internal func clearHover() { simulation.setHover(nil) }
    internal var highlightAnchor: Int? { selectedNodeIndex ?? simulation.hoveredNodeIndex }

    /// True while the user is actively moving the camera or cursor over the
    /// canvas — see `WikiSimulationStore.isInteracting`, which the canvas
    /// observes directly.
    internal var isInteracting: Bool { simulation.isInteracting }

    /// Mark a camera/cursor interaction as ongoing (leading-edge publish on
    /// the simulation store; full fidelity returns a beat after the last move).
    internal func noteInteraction() { simulation.noteInteraction() }

    func selectedNodeNeighbors() -> [Int] {
        guard let sel = selectedNodeIndex else { return [] }
        return Array(neighbors(of: sel))
    }

    func neighbors(of anchor: Int) -> Set<Int> {
        guard adjacency.indices.contains(anchor) else { return [] }
        return adjacency[anchor]
    }

    func isNodeConnectedToSelection(_ index: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        if index == anchor { return true }
        return adjacency.indices.contains(anchor) && adjacency[anchor].contains(index)
    }

    func linkIsConnectedToSelection(_ source: Int, _ target: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        return source == anchor || target == anchor
    }

    func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom; let newZoom = max(0.3, min(5.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        noteInteraction()
        panOffset.width += point.x * (oldZoom - newZoom)
        panOffset.height += point.y * (oldZoom - newZoom)
        zoom = newZoom
    }

    func resetView() { panOffset = .zero; zoom = 1.0 }
}

// MARK: - Page editing (wiki.update)

extension WikiGraphViewModel {

    /// True when the loaded source supports page writes — the home gateway's
    /// harness wiki. CodeGraphSource override sources are read-only, so their
    /// readers hide the Edit affordance.
    internal var supportsPageEditing: Bool {
        loadedSource == nil || loadedSource is GatewayClient
    }

    /// Save an edited page through `wiki.update` against the SELECTED wiki,
    /// then refresh the cache entry and rescan the graph in place (title/
    /// type/tag/link changes need a fresh scan; the reader keeps its
    /// selection and the loading overlay stays down).
    ///
    /// Throws `WikiUpdateConflict` when the page changed since `ifMatch` was
    /// read — the editor offers reload-latest / force-save from it.
    internal func savePage(
        client: GatewayClient,
        path: String,
        body: String,
        frontmatter: [String: String]?,
        ifMatch: String?,
        force: Bool = false
    ) async throws -> WikiPageContent {
        let content = try await client.wikiUpdate(
            path: path, body: body, frontmatter: frontmatter,
            ifMatch: ifMatch, force: force, wiki: loadedWiki
        )
        storeContent(content, for: path)
        await rescanGraphInPlace(client: client, wiki: loadedWiki)
        return content
    }

    /// Lightweight rescan after a page save — refreshes the graph (edits can
    /// add/remove wikilinks or change title/type/tags) without the full
    /// `load` ceremony: the content cache survives and the surface doesn't
    /// flash its loading overlay.
    private func rescanGraphInPlace(client: GatewayClient, wiki: String?) async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let newGraph = try await client.wikiScan(wiki: wiki)
            guard generation == loadGeneration else { return }
            self.graph = newGraph
            setupSimulation()
            graphCache.store(newGraph, identity: client.cacheIdentity, wiki: wiki)
        } catch {
            // The save itself succeeded — a rescan hiccup just leaves the
            // pre-save graph on screen until the next load.
            log.warning("post-save wiki.scan failed: \(error.localizedDescription)")
        }
    }
}

extension CGPoint { var width: CGFloat { x }; var height: CGFloat { y } }
extension CGVector { static let zero = CGVector.zero }

// MARK: - Layout: pre-settle, fit-to-view, and the shared 2D physics step

extension WikiGraphViewModel {

    /// Canvas size used for seeding, settling, and framing. When the graph
    /// loads BEFORE the surface is ever shown (the connect-time warm load),
    /// canvasSize is still zero — fall back to a nominal size so the layout
    /// settles in the background and the first open paints an already-framed
    /// graph instead of the "Laying out…" spinner. The one-time re-fit on
    /// first display (`refitForFirstDisplayIfNeeded`) corrects the framing
    /// for the real size.
    internal static let nominalCanvasSize = CGSize(width: 1280, height: 800)
    internal var effectiveCanvasSize: CGSize {
        canvasSize == .zero ? Self.nominalCanvasSize : canvasSize
    }

    /// One-time framing correction when the surface first appears after a
    /// background (nominal-size) settle. Mid-settle first-opens are left to
    /// the settle completion, which already frames for the live size.
    internal func refitForFirstDisplayIfNeeded() {
        guard settledAgainstNominalSize, canvasSize != .zero, !isSettling else { return }
        settledAgainstNominalSize = false
        fitToView()
    }

    /// Relaxes the freshly-seeded 2D layout off the main thread, then reveals
    /// it already-settled and framed — the graph "clicks into place" instead
    /// of visibly exploding apart. The store runs the relaxation in
    /// cancellable chunks (a reload drops it) and adopts the result at rest;
    /// above `WikiSimulationStore.liveSimulationNodeLimit` the graph then
    /// stays frozen until a drag.
    func settleAndReveal() {
        guard !is3D, nodeMeta.count > 1 else {
            isSettling = false
            return
        }
        isSettling = true
        // Track whether this settle ran before any real canvas existed
        // (the connect-time preload) — the canvas re-frames once on its
        // first display to correct for its real size.
        settledAgainstNominalSize = canvasSize == .zero
        Task { @MainActor [weak self] in
            guard let self else { return }
            let adopted = await self.simulation.presettle()
            guard adopted else {
                // Superseded by a newer settle (which owns the flag) or by a
                // reset with no settle at all (3D) — only the latter clears.
                if !self.simulation.isPresettling { self.isSettling = false }
                return
            }
            // Frame the whole graph, unless a page is already selected —
            // then keep that node centered (Show in Graph / mode switch).
            if let sel = self.selectedNodeIndex, self.nodeMeta.indices.contains(sel) {
                self.centerOnNode(sel)
            } else {
                self.fitToView()
            }
            // fitToView just framed for the LIVE effective size — if a
            // real canvas appeared mid-settle it got the right frame; if
            // not, the first display re-fits once via the flag.
            self.settledAgainstNominalSize = self.canvasSize == .zero
            self.isSettling = false
        }
    }

    /// Frames the whole 2D graph in the canvas: centers its bounding box and
    /// picks a zoom that leaves a comfortable margin, so nodes read at a
    /// legible size the moment the view appears (clamped to the pinch range).
    func fitToView() {
        guard !is3D, simulation.positions.count > 1 else { return }
        let size = effectiveCanvasSize
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for position in simulation.positions {
            minX = min(minX, position.x); maxX = max(maxX, position.x)
            minY = min(minY, position.y); maxY = max(maxY, position.y)
        }
        let graphW = max(maxX - minX, 1), graphH = max(maxY - minY, 1)
        let margin: CGFloat = 80
        let fitZoom = min(
            (size.width - margin * 2) / graphW,
            (size.height - margin * 2) / graphH
        )
        let newZoom = max(0.3, min(1.6, fitZoom))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        zoom = newZoom
        panOffset = CGSize(
            width: size.width / 2 - cx * newZoom,
            height: size.height / 2 - cy * newZoom
        )
    }
}
