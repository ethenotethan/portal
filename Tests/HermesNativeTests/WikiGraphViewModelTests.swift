import Testing
import Foundation
@testable import HermesNative

@Suite("Wiki Shared Selection Plane")
@MainActor
struct WikiGraphViewModelTests {

    private func page(_ id: String, path: String) -> WikiPage {
        WikiPage(
            id: id, title: id.capitalized, type: "concept", tags: [],
            path: path, created: nil, updated: nil, confidence: nil,
            contested: false, tagPath: [], integrationLinks: []
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

    @Test("Open in Files switches mode and opens the page")
    func openInFiles() {
        let vm = makeVM()
        vm.openInFiles(path: "concepts/beta.md")
        #expect(vm.viewMode == .files)
        #expect(vm.selectedPath == "concepts/beta.md")
        #expect(vm.showPageDetail == false)
    }

    @Test("Show in Graph switches to 2D and selects the node")
    func showInGraph() {
        let vm = makeVM()
        vm.viewMode = .files
        vm.navigate(to: "concepts/beta.md")
        vm.showCurrentPageInGraph()
        #expect(vm.viewMode == .twoD)
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
            func search(query: String, limit: Int) async throws -> [WikiSearchResult] { [] }
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
}
