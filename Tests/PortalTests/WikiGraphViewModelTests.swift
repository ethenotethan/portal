import Testing
import Foundation
import SwiftUI
@testable import Portal

@Suite("Wiki Shared Selection Plane")
@MainActor
struct WikiGraphViewModelTests {

    private func page(_ id: String, path: String, tagPath: [String] = []) -> WikiPage {
        WikiPage(
            id: id, title: id.capitalized, type: "concept", tags: [],
            path: path, created: nil, updated: nil, confidence: nil,
            contested: false, tagPath: tagPath, integrationLinks: []
        )
    }

    private func makeVM() -> WikiGraphViewModel {
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        vm.graph = WikiGraph(
            pages: [
                page("alpha", path: "concepts/alpha.md"),
                page("beta", path: "concepts/beta.md"),
                page("gamma", path: "entities/gamma.md"),
            ],
            links: [
                WikiLink(source: "alpha", target: "beta", type: "wikilink"),
                WikiLink(source: "gamma", target: "beta", type: "wikilink"),
            ]
        )
        vm.setupSimulation()
        return vm
    }

    @Test("Selecting a node makes its page the shared current page")
    func nodeSelectSetsPath() {
        let vm = makeVM()
        guard let idx = vm.simNodes.firstIndex(where: { $0.id == "beta" }) else {
            Issue.record("beta node missing")
            return
        }
        vm.selectNode(idx)
        #expect(vm.selectedPath == "concepts/beta.md")
        #expect(vm.selectedNodeIndex == idx)
        #expect(vm.selectedPage?.id == "beta")
    }

    @Test("Navigating to a path selects the corresponding graph node")
    func pathSelectSetsNode() {
        let vm = makeVM()
        vm.navigate(to: "entities/gamma.md")
        let idx = vm.selectedNodeIndex
        #expect(idx != nil)
        if let idx { #expect(vm.simNodes[idx].id == "gamma") }
    }

    @Test("Node select ↔ path select round-trip")
    func selectionRoundTrip() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        let nodeIdx = vm.selectedNodeIndex
        #expect(nodeIdx != nil)
        guard let nodeIdx else { return }
        // Re-selecting the same node keeps the same path.
        vm.selectNode(nodeIdx)
        #expect(vm.selectedPath == "concepts/alpha.md")
    }

    @Test("Navigating to a path outside the graph clears node selection")
    func unknownPathClearsNode() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        #expect(vm.selectedNodeIndex != nil)
        vm.navigate(to: "changesets/not-in-graph.md")
        #expect(vm.selectedPath == "changesets/not-in-graph.md")
        #expect(vm.selectedNodeIndex == nil)
    }

    @Test("History push/pop across navigate, back, and forward")
    func historyPushPop() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        vm.navigate(to: "concepts/beta.md")
        vm.navigate(to: "entities/gamma.md")
        #expect(vm.backStack == ["concepts/alpha.md", "concepts/beta.md"])
        #expect(vm.forwardStack.isEmpty)

        vm.goBack()
        #expect(vm.selectedPath == "concepts/beta.md")
        #expect(vm.forwardStack == ["entities/gamma.md"])

        vm.goBack()
        #expect(vm.selectedPath == "concepts/alpha.md")
        #expect(!vm.canGoBack)

        vm.goForward()
        #expect(vm.selectedPath == "concepts/beta.md")
        #expect(vm.backStack == ["concepts/alpha.md"])

        // A fresh navigation clears the forward stack.
        vm.navigate(to: "concepts/alpha.md")
        #expect(vm.forwardStack.isEmpty)
    }

    @Test("Navigating to the current path is a no-op for history")
    func navigateSamePathNoop() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        vm.navigate(to: "concepts/alpha.md")
        #expect(vm.backStack.isEmpty)
    }

    @Test("Sim rebuild re-syncs node selection from the shared path")
    func rebuildKeepsSelection() {
        let vm = makeVM()
        vm.navigate(to: "concepts/beta.md")
        vm.setupSimulation()
        let idx = vm.selectedNodeIndex
        #expect(idx != nil)
        if let idx { #expect(vm.simNodes[idx].id == "beta") }
    }

    @Test("Backlink index is built from the graph on assignment")
    func backlinkIndexBuilt() {
        let vm = makeVM()
        let betaBacklinks = vm.backlinks(for: vm.graph.pages.first { $0.id == "beta" })
        #expect(betaBacklinks.map(\.id).sorted() == ["alpha", "gamma"])
        let alphaBacklinks = vm.backlinks(for: vm.graph.pages.first { $0.id == "alpha" })
        #expect(alphaBacklinks.isEmpty)
    }

    @Test("Taxonomy tree retains nested paths and shared prefixes")
    internal func taxonomyTreeBuildsNestedPaths() {
        let graph = WikiGraph(
            pages: [
                page("speculation", path: "concepts/speculation.md", tagPath: ["ml/inference/speculative-decoding"]),
                page("training", path: "concepts/training.md", tagPath: ["ml/training"]),
            ],
            links: []
        )

        #expect(graph.tagPathTree.flatPaths == [
            "ml", "ml/inference", "ml/inference/speculative-decoding", "ml/training",
        ])
    }

    @Test("Clearing page selection resets path, history, and node")
    func clearSelection() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        vm.navigate(to: "concepts/beta.md")
        vm.clearPageSelection()
        #expect(vm.selectedPath == nil)
        #expect(vm.selectedNodeIndex == nil)
        #expect(!vm.canGoBack)
        #expect(!vm.canGoForward)
        #expect(vm.showPageDetail == false)
    }

    @Test("Cached content stores and reports failures for the current page")
    func contentCacheStoreAndFail() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        let content = WikiPageContent(frontmatter: ["title": "Alpha"], body: "hello", path: "concepts/alpha.md")
        vm.storeContent(content, for: "concepts/alpha.md")
        #expect(vm.cachedContent(for: "concepts/alpha.md")?.body == "hello")

        vm.navigate(to: "concepts/beta.md")
        vm.storeContent(nil, for: "concepts/beta.md")
        #expect(vm.failedPath == "concepts/beta.md")
        // A failure for a page that is no longer current is not surfaced.
        vm.navigate(to: "entities/gamma.md")
        vm.storeContent(nil, for: "concepts/beta.md")
        #expect(vm.failedPath == "concepts/beta.md")
    }

    @Test("Switching wikis clears selection and history; reloading the same wiki keeps them")
    func wikiSwitchClearsSelection() {
        let vm = makeVM()
        vm.prepareForLoad(wiki: "research")
        vm.navigate(to: "concepts/alpha.md")
        vm.navigate(to: "concepts/beta.md")

        // Same wiki reload: selection and history survive (cache drops).
        vm.storeContent(
            WikiPageContent(frontmatter: [:], body: "b", path: "concepts/beta.md"),
            for: "concepts/beta.md"
        )
        vm.prepareForLoad(wiki: "research")
        #expect(vm.selectedPath == "concepts/beta.md")
        #expect(vm.canGoBack)
        #expect(vm.cachedContent(for: "concepts/beta.md") == nil)

        // Different wiki: everything clears.
        vm.prepareForLoad(wiki: "other")
        #expect(vm.selectedPath == nil)
        #expect(!vm.canGoBack)
        #expect(!vm.canGoForward)
        #expect(vm.selectedNodeIndex == nil)
    }

    @Test("Reveal in file tree opens the sidebar with the page selected")
    func revealInFileTree() {
        let vm = makeVM()
        vm.revealInFileTree(path: "concepts/beta.md")
        #expect(vm.showFileTree)
        #expect(vm.selectedPath == "concepts/beta.md")
    }

    @Test("Show in Graph closes the reader, drops to 2D, and selects the node")
    func showInGraph() {
        let vm = makeVM()
        vm.is3D = true
        vm.navigate(to: "concepts/beta.md")
        vm.showPageDetail = true
        vm.showCurrentPageInGraph()
        #expect(vm.showPageDetail == false)
        #expect(vm.is3D == false)
        let idx = vm.selectedNodeIndex
        #expect(idx != nil)
        if let idx {
            #expect(vm.simNodes[idx].id == "beta")
            // Centered: node's screen position lands on the canvas center.
            let pos = vm.simNodes[idx].position
            let screenX = pos.x * vm.zoom + vm.panOffset.width
            let screenY = pos.y * vm.zoom + vm.panOffset.height
            #expect(abs(screenX - 400) < 0.001)
            #expect(abs(screenY - 300) < 0.001)
        }
    }

    @Test("Activating a node selects its page and opens the reader")
    func activateNodeOpensReader() {
        let vm = makeVM()
        guard let idx = vm.simNodes.firstIndex(where: { $0.id == "alpha" }) else {
            Issue.record("alpha node missing")
            return
        }
        vm.activateNode(idx)
        #expect(vm.selectedPath == "concepts/alpha.md")
        // The reader opens over the always-alive graph: a right-docked panel on
        // macOS, the sheet on iOS — both keyed off showPageDetail.
        #expect(vm.showPageDetail)
    }

    @Test("Deactivating (empty-canvas tap) closes the reader but keeps history")
    func deactivateClosesReader() {
        let vm = makeVM()
        vm.navigate(to: "concepts/alpha.md")
        vm.navigate(to: "concepts/beta.md")
        vm.showPageDetail = true
        vm.deactivateSelection()
        #expect(vm.showPageDetail == false)
        #expect(vm.selectedNodeIndex == nil)
        // The shared path and history survive for the sidebar/timeline.
        #expect(vm.selectedPath == "concepts/beta.md")
        #expect(vm.canGoBack)
    }

    @Test("3D rendering toggle reseeds the sim and keeps the page selection")
    func renderingToggleKeepsSelection() {
        let vm = makeVM()
        vm.navigate(to: "entities/gamma.md")

        vm.setRendering3D(true)
        #expect(vm.is3D)
        var idx = vm.selectedNodeIndex
        #expect(idx != nil)
        if let idx { #expect(vm.simNodes[idx].id == "gamma") }

        vm.setRendering3D(false)
        #expect(!vm.is3D)
        idx = vm.selectedNodeIndex
        #expect(idx != nil)
        if let idx {
            #expect(vm.simNodes[idx].id == "gamma")
            // Back in 2D the selected node is re-centered.
            let pos = vm.simNodes[idx].position
            #expect(abs(pos.x * vm.zoom + vm.panOffset.width - 400) < 0.001)
        }

        // Same-value set is a no-op (no reseed churn).
        let positions = vm.simNodes.map(\.position)
        vm.setRendering3D(false)
        #expect(vm.simNodes.map(\.position) == positions)
    }

    @Test("Fit-to-view centers the graph's bounding box in the canvas")
    func fitToViewCentersGraph() {
        let vm = makeVM()
        // Place nodes at a known, off-center bounding box.
        for i in vm.simNodes.indices {
            vm.simNodes[i].position = CGPoint(x: 100 + CGFloat(i) * 200, y: 100)
        }
        vm.fitToView()
        // The bounding-box center must map to the canvas center at the chosen zoom.
        let minX = vm.simNodes.map(\.position.x).min()!
        let maxX = vm.simNodes.map(\.position.x).max()!
        let cx = (minX + maxX) / 2
        let screenX = cx * vm.zoom + vm.panOffset.width
        #expect(abs(screenX - vm.canvasSize.width / 2) < 0.001)
        // Zoom stays within the legible clamp range.
        #expect(vm.zoom >= 0.3 && vm.zoom <= 1.6)
    }

    /// Regression: loadedSource was weak, and ContentView rebuilds its
    /// override client per body evaluation — the ref died between graph load
    /// and page read, so the reader fell back to the home gateway and every
    /// Centaur page 404'd. The VM must retain the source it loaded from.
    @Test("Override source outlives its creation scope for page reads")
    func overrideSourceRetained() async {
        final class StubSource: WikiSource {
            var pageFetches = 0
            func fetchGraph() async throws -> WikiGraph {
                WikiGraph(pages: [], links: [])
            }
            func fetchPage(path: String) async throws -> WikiPageContent {
                pageFetches += 1
                return WikiPageContent(frontmatter: [:], body: "# hi", path: path)
            }
        }

        let vm = WikiGraphViewModel()
        weak var weakStub: StubSource?
        do {
            let stub = StubSource()
            weakStub = stub
            await vm.load(source: stub)
        }
        // The creating scope is gone; only the VM's reference remains.
        #expect(weakStub != nil, "VM must retain the source the graph loaded from")

        await vm.ensureContentLoaded(client: GatewayClient(), path: "concepts/alpha.md")
        #expect(weakStub?.pageFetches == 1, "page reads must route to the override source, not the home gateway")
    }

    // MARK: - Cold-open disk cache

    /// On a cold open the graph should paint from the disk cache instantly and
    /// survive a failing scan, so the surface is never blank behind "Loading…".
    /// A default (disconnected) GatewayClient throws .notConnected from
    /// wiki.scan immediately, standing in for the cold-network path.
    @Test("Cold open paints the cached graph and it survives a scan failure")
    internal func coldOpenPaintsCache() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-cache-vm-\(UUID().uuidString)", isDirectory: true)
        let cache = WikiGraphCache(directory: dir)
        let client = GatewayClient()  // disconnected → wiki.scan throws

        // Seed the cache under this client's identity + wiki selection.
        let seeded = WikiGraph(pages: [page("alpha", path: "concepts/alpha.md")], links: [])
        cache.store(seeded, identity: client.cacheIdentity, wiki: "main")
        for _ in 0..<50 {
            if await cache.load(identity: client.cacheIdentity, wiki: "main") != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let vm = WikiGraphViewModel(graphCache: cache)
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(client: client, wiki: "main")

        // Scan failed, but the cached graph must remain on screen (not wiped).
        #expect(vm.graph.pages.contains { $0.id == "alpha" },
                "cold-open graph should be painted from the disk cache")
        #expect(!vm.graph.pages.isEmpty, "a failing scan must not blank the cached graph")
    }

    @Test("No cache entry leaves an empty graph for the overlay to catch")
    internal func coldOpenNoCache() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-cache-vm-\(UUID().uuidString)", isDirectory: true)
        let vm = WikiGraphViewModel(graphCache: WikiGraphCache(directory: dir))
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(client: GatewayClient(), wiki: "main")
        #expect(vm.graph.pages.isEmpty, "no cache + failed scan → empty graph (overlay shows)")
    }

    // MARK: - Event-type taxonomy

    /// A source whose graph declares event types, so the VM has definition
    /// pages to fetch frontmatter for.
    private final class TaxonomySource: WikiSource {
        var graph: WikiGraph
        var frontmatter: [String: [String: String]]
        /// Paths fetched, in order — asserts the VM reads definitions and
        /// nothing else.
        var fetchedPaths: [String] = []
        /// Paths whose fetch should throw, standing in for an unreadable page.
        var failingPaths: Set<String> = []

        init(graph: WikiGraph, frontmatter: [String: [String: String]]) {
            self.graph = graph
            self.frontmatter = frontmatter
        }

        struct Missing: Error {}

        func fetchGraph() async throws -> WikiGraph { graph }

        func fetchPage(path: String) async throws -> WikiPageContent {
            fetchedPaths.append(path)
            if failingPaths.contains(path) { throw Missing() }
            return WikiPageContent(frontmatter: frontmatter[path] ?? [:], body: "", path: path)
        }
    }

    private func eventTypePage(_ id: String, title: String) -> WikiPage {
        WikiPage(
            id: id, title: title, type: WikiEventTypeRegistry.definitionPageType,
            tags: [], path: "event-types/\(id).md", created: nil, updated: nil,
            confidence: nil, contested: false, tagPath: [], integrationLinks: []
        )
    }

    /// The point of the whole feature: a kind the wiki declares must resolve to
    /// what the WIKI said, with no client release involved.
    @Test("Loading a wiki resolves its declared event types from its own pages")
    internal func loadResolvesDeclaredEventTypes() async {
        let source = TaxonomySource(
            graph: WikiGraph(
                pages: [
                    eventTypePage("ingest", title: "Source ingest"),
                    page("alpha", path: "concepts/alpha.md"),
                ],
                links: []
            ),
            frontmatter: [
                "event-types/ingest.md": [
                    "event_kind": "ingest",
                    "glyph": "tray.and.arrow.down",
                    "produces_changes": "true",
                ],
            ]
        )

        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(source: source)

        let ingest = vm.eventTypes.resolve("ingest")
        #expect(ingest.isDeclared)
        #expect(ingest.label == "Source ingest")
        #expect(ingest.glyph == "tray.and.arrow.down")
        #expect(ingest.pagePath == "event-types/ingest.md", "the chip needs a page to click through to")
        #expect(vm.eventTypes.changeProducingKinds.contains("ingest"))
        // Only definition pages are fetched — this must not become a scan of
        // every page in the wiki.
        #expect(source.fetchedPaths == ["event-types/ingest.md"])
    }

    /// The pre-seed state, and a legitimate steady state. Nothing regresses:
    /// an undeclared kind still resolves, just derived.
    @Test("A wiki declaring no event types still resolves every kind")
    internal func noDeclarationsStillResolves() async {
        let source = TaxonomySource(
            graph: WikiGraph(pages: [page("alpha", path: "concepts/alpha.md")], links: []),
            frontmatter: [:]
        )
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(source: source)

        #expect(vm.eventTypes.isEmpty)
        #expect(source.fetchedPaths.isEmpty, "no definition pages → no page fetches")
        let derived = vm.eventTypes.resolve("github_pr")
        #expect(!derived.isDeclared)
        #expect(derived.label == "Github pr")
        #expect(derived.pagePath == nil, "nothing to open for a kind no page defines")
    }

    /// A definition page that won't load leaves its kind derived — the same
    /// outcome as never declaring it. It must not take the other declarations
    /// down with it.
    @Test("An unreadable definition page doesn't lose the readable ones")
    internal func unreadableDefinitionIsSkipped() async {
        let source = TaxonomySource(
            graph: WikiGraph(
                pages: [
                    eventTypePage("ingest", title: "Source ingest"),
                    eventTypePage("broken", title: "Broken"),
                ],
                links: []
            ),
            frontmatter: ["event-types/ingest.md": ["event_kind": "ingest"]]
        )
        source.failingPaths = ["event-types/broken.md"]

        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(source: source)

        #expect(vm.eventTypes.resolve("ingest").isDeclared)
        #expect(vm.eventTypes.declaredTypes.count == 1)
    }

    /// A wiki that declared types and then deleted them must fall back to
    /// derivation rather than keep answering from a stale registry.
    @Test("Reloading a wiki that dropped its definitions clears the registry")
    internal func droppedDefinitionsClearRegistry() async {
        let declared = WikiGraph(pages: [eventTypePage("ingest", title: "Source ingest")], links: [])
        let source = TaxonomySource(
            graph: declared,
            frontmatter: ["event-types/ingest.md": ["event_kind": "ingest"]]
        )
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(source: source)
        #expect(!vm.eventTypes.isEmpty)

        source.graph = WikiGraph(pages: [page("alpha", path: "concepts/alpha.md")], links: [])
        await vm.load(source: source)
        #expect(vm.eventTypes.isEmpty, "stale declarations must not outlive the pages that made them")
    }

    @Test("A gateway switch drops the previous wiki's taxonomy")
    internal func gatewaySwitchClearsRegistry() async {
        let source = TaxonomySource(
            graph: WikiGraph(pages: [eventTypePage("ingest", title: "Source ingest")], links: []),
            frontmatter: ["event-types/ingest.md": ["event_kind": "ingest"]]
        )
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        await vm.load(source: source)
        #expect(!vm.eventTypes.isEmpty)

        vm.resetForGatewaySwitch()
        #expect(vm.eventTypes.isEmpty)
    }

    // MARK: - Typed edge labels

    /// The relationship to render is derived from the wire shape the gateway
    /// actually sends (SCHEMA §3.3): the predicate rides in `type`, prettified
    /// for display; an explicit `label` wins when present; a plain wikilink
    /// renders nothing.
    @Test("displayRelation derives the edge label from type, label, or neither")
    internal func displayRelationDerivation() {
        // Gateway's real shape: predicate in `type`, no label → prettified.
        #expect(WikiLink(source: "a", target: "b", type: "deployed_on").displayRelation == "deployed on")
        // An explicit label wins over the type slug.
        #expect(WikiLink(source: "a", target: "b", type: "deployed_on", label: "runs on").displayRelation == "runs on")
        // A plain wikilink has no relationship to draw.
        #expect(WikiLink(source: "a", target: "b", type: "wikilink").displayRelation == nil)
    }

    /// The derived relationship must reach the renderer: `simLinkLabels` stays
    /// index-aligned with `simLinks` so the canvas can label each edge, and a
    /// plain link contributes `nil`.
    @Test("Edge labels align 1:1 with sim links, nil for plain links")
    internal func edgeLabelsAlignWithLinks() {
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        vm.graph = WikiGraph(
            pages: [
                page("alpha", path: "concepts/alpha.md"),
                page("beta", path: "concepts/beta.md"),
                page("gamma", path: "entities/gamma.md"),
            ],
            links: [
                WikiLink(source: "alpha", target: "beta", type: "deployed_on"),
                WikiLink(source: "gamma", target: "beta", type: "wikilink"),
            ]
        )
        vm.setupSimulation()

        #expect(vm.simLinks.count == 2)
        #expect(vm.simLinkLabels.count == vm.simLinks.count, "labels must stay index-aligned with edges")
        #expect(vm.simLinkLabels.contains("deployed on"), "the predicate edge renders its prettified type")
        #expect(vm.simLinkLabels.contains(nil), "a plain wikilink has no relationship label")
    }

    /// A link whose endpoint isn't in the page set is dropped from `simLinks`;
    /// its label must be dropped with it, or every later edge mislabels.
    @Test("Dropping a dangling link keeps labels aligned to surviving edges")
    internal func danglingLinkKeepsLabelsAligned() {
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 800, height: 600)
        vm.graph = WikiGraph(
            pages: [
                page("alpha", path: "concepts/alpha.md"),
                page("beta", path: "concepts/beta.md"),
            ],
            links: [
                WikiLink(source: "alpha", target: "ghost", type: "operates"),
                WikiLink(source: "alpha", target: "beta", type: "deployed_on"),
            ]
        )
        vm.setupSimulation()

        #expect(vm.simLinks.count == 1, "the link to a non-existent page is dropped")
        #expect(vm.simLinkLabels == ["deployed on"], "the surviving edge keeps its own label, not the dropped one's")
    }

    // MARK: - Folder-branch colors

    /// A page with a flat `type` and an explicit hierarchical `path` — the real
    /// compendium shape, where the folder (not the type) carries the hierarchy.
    private func foldered(_ id: String, type: String, path: String) -> WikiPage {
        WikiPage(
            id: id, title: id.capitalized, type: type, tags: [],
            path: path, created: nil, updated: nil, confidence: nil,
            contested: false, tagPath: [], integrationLinks: []
        )
    }

    private func node(path: String, type: String) -> WikiGraphViewModel.SimNode {
        WikiGraphViewModel.SimNode(id: path, position: .zero, type: type, label: path, path: path)
    }

    /// The grouping key is the page's folder: a path collapses to its directory,
    /// and a root-level file has no branch.
    @Test("branchKey groups a page by its folder path")
    internal func branchKeyDerivation() {
        #expect(WikiGraphViewModel.branchKey(for: "entities/chain/base.md") == "entities/chain")
        #expect(WikiGraphViewModel.branchKey(for: "entities/chain/solana.md") == "entities/chain")
        #expect(WikiGraphViewModel.branchKey(for: "entities/org/0x.md") == "entities/org")
        #expect(WikiGraphViewModel.branchKey(for: "SCHEMA.md") == nil, "a root-level file has no folder")
        #expect(WikiGraphViewModel.branchKey(for: "index.md") == nil)
        #expect(WikiGraphViewModel.branchKey(for: "") == nil)
    }

    /// Every node sharing a folder gets one color; different folders get
    /// different colors; and no foldered node — even one with a flat, unknown
    /// `type` like "org" or "chain" — falls back to the neutral grey.
    @Test("Nodes sharing a folder share a color, unique per folder, never grey")
    internal func foldersAreColoredByBranch() {
        let vm = WikiGraphViewModel()
        vm.graph = WikiGraph(
            pages: [
                foldered("base", type: "chain", path: "entities/chain/base.md"),
                foldered("solana", type: "chain", path: "entities/chain/solana.md"),
                foldered("0x", type: "org", path: "entities/org/0x.md"),
            ],
            links: []
        )

        let chainBase = vm.color(forNode: node(path: "entities/chain/base.md", type: "chain"))
        let chainSolana = vm.color(forNode: node(path: "entities/chain/solana.md", type: "chain"))
        let org = vm.color(forNode: node(path: "entities/org/0x.md", type: "org"))
        let grey = Color(hex: "aaaaaa")

        #expect(chainBase == chainSolana, "siblings under entities/chain share one color")
        #expect(chainBase != org, "a different folder gets a unique color")
        #expect(chainBase != grey, "a foldered flat type is no longer the default grey")
        #expect(org != grey)
    }

    /// A root-level page (no folder) uses the flat-type palette: a known root
    /// type keeps its color, an unknown one stays grey — and the palette itself
    /// is unchanged.
    @Test("Root-level nodes use the flat-type palette")
    internal func rootLevelNodesUsePalette() {
        let vm = WikiGraphViewModel()
        vm.graph = WikiGraph(pages: [foldered("base", type: "chain", path: "entities/chain/base.md")], links: [])

        #expect(vm.color(forNode: node(path: "index.md", type: "meta")) == Color(hex: "5ad4e6"), "a known root type keeps its color")
        #expect(vm.color(forNode: node(path: "wat.md", type: "wat")) == Color(hex: "aaaaaa"), "an unknown root type stays grey")
        #expect(vm.color(for: "entity") == Color(hex: "7c7cff"), "the flat palette is unchanged")
    }
}
