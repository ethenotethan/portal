import CoreGraphics
import Testing
@testable import HermesNative

// The macOS reader is a right-docked panel driven by the shared selection
// plane (no per-card history). These exercise the three read-only focus levels
// through the view model: Peek (open/close), fullscreen (toggle), and Compare
// (pin/unpin), plus divider-width clamping — all without a running view.
@Suite("Wiki docked reader")
@MainActor
internal struct WikiDockedReaderTests {

    private func page(_ id: String, path: String) -> WikiPage {
        WikiPage(
            id: id, title: id.capitalized, type: "concept", tags: [],
            path: path, created: nil, updated: nil, confidence: nil,
            contested: false, tagPath: [], integrationLinks: []
        )
    }

    private func makeVM() -> WikiGraphViewModel {
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 1000, height: 700)
        vm.graph = WikiGraph(
            pages: [
                page("alpha", path: "a.md"),
                page("beta", path: "b.md"),
                page("gamma", path: "c.md"),
            ],
            links: []
        )
        vm.setupSimulation()
        return vm
    }

    // MARK: - Peek open / close

    @Test("Selecting a page opens the docked reader for it")
    internal func openReader() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.openReaderForSelection()
        #expect(vm.showPageDetail)
        #expect(vm.selectedPath == "a.md")
        #expect(!vm.isComparing)
    }

    @Test("Deactivating closes the reader and drops fullscreen")
    internal func closeReader() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.openReaderForSelection()
        vm.toggleReaderFullscreen()
        #expect(vm.readerFullscreen)

        vm.deactivateSelection()
        #expect(!vm.showPageDetail)
        #expect(!vm.readerFullscreen)
    }

    @Test("Opening a page with no selection is a no-op")
    internal func openWithoutSelection() {
        let vm = makeVM()
        vm.openReaderForSelection()
        #expect(!vm.showPageDetail)
    }

    // MARK: - Fullscreen toggle

    @Test("Fullscreen toggles only while a page is open")
    internal func fullscreenGuarded() {
        let vm = makeVM()
        // No page open → toggle is inert (can't strand a blank fullscreen).
        vm.toggleReaderFullscreen()
        #expect(!vm.readerFullscreen)

        vm.navigate(to: "a.md")
        vm.openReaderForSelection()
        vm.toggleReaderFullscreen()
        #expect(vm.readerFullscreen)
        vm.toggleReaderFullscreen()
        #expect(!vm.readerFullscreen)
    }

    @Test("Show-in-graph exits fullscreen and closes the reader")
    internal func showInGraphExitsFullscreen() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.openReaderForSelection()
        vm.toggleReaderFullscreen()

        vm.showCurrentPageInGraph()
        #expect(!vm.showPageDetail)
        #expect(!vm.readerFullscreen)
    }

    // MARK: - Compare (pin / unpin)

    @Test("Pinning the current page then opening another compares the two")
    internal func pinBuildsComparison() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.openReaderForSelection()
        vm.pinCurrentPage()
        #expect(vm.isPinned("a.md"))

        vm.navigate(to: "b.md")
        // Active page first, then the pinned one.
        #expect(vm.comparePaths == ["b.md", "a.md"])
        #expect(vm.isComparing)
    }

    @Test("The active page is never duplicated in the compare set")
    internal func activeNotDuplicated() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.pinCurrentPage()
        // Still on a.md, which is both active and pinned.
        #expect(vm.comparePaths == ["a.md"])
        #expect(!vm.isComparing)
    }

    @Test("Pinning is idempotent and unpin removes exactly one page")
    internal func pinUnpin() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.pinCurrentPage()
        vm.pinCurrentPage() // no duplicate
        vm.navigate(to: "b.md")
        vm.pinCurrentPage()
        vm.navigate(to: "c.md")
        #expect(vm.comparePaths == ["c.md", "a.md", "b.md"])

        vm.unpin("a.md")
        #expect(vm.comparePaths == ["c.md", "b.md"])
        vm.clearComparison()
        #expect(!vm.isComparing)
        #expect(vm.comparePaths == ["c.md"])
    }

    @Test("Closing the reader clears the comparison and pins")
    internal func closeClearsPins() {
        let vm = makeVM()
        vm.navigate(to: "a.md")
        vm.pinCurrentPage()
        vm.navigate(to: "b.md")
        #expect(vm.isComparing)

        vm.closePage()
        #expect(vm.comparePaths.isEmpty)
        #expect(!vm.isComparing)
    }

    @Test("Switching wikis clears the reader, fullscreen, and pins")
    internal func wikiSwitchResets() {
        let vm = makeVM()
        vm.prepareForLoad(wiki: "one")
        vm.navigate(to: "a.md")
        vm.openReaderForSelection()
        vm.pinCurrentPage()
        vm.navigate(to: "b.md")
        vm.toggleReaderFullscreen()

        vm.prepareForLoad(wiki: "two") // different wiki → clearPageSelection
        #expect(!vm.showPageDetail)
        #expect(!vm.readerFullscreen)
        #expect(vm.comparePaths.isEmpty)
        #expect(vm.selectedPath == nil)
    }

    // MARK: - Divider width clamping

    @Test("Divider width clamps to a floor and ~70% of the surface")
    internal func widthClamps() {
        let vm = makeVM()
        let surface: CGFloat = 1000

        vm.setReaderWidth(50, surfaceWidth: surface) // below floor
        #expect(vm.readerWidth == WikiGraphViewModel.minReaderWidth)

        vm.setReaderWidth(5000, surfaceWidth: surface) // beyond the cap
        #expect(vm.readerWidth == surface * 0.7)

        vm.setReaderWidth(480, surfaceWidth: surface) // in range
        #expect(vm.readerWidth == 480)
    }

    @Test("On a tiny surface the floor wins over the 70% cap")
    internal func widthTinySurface() {
        let vm = makeVM()
        // 70% of 300 = 210 < floor(320); the floor must not fall below itself.
        vm.setReaderWidth(400, surfaceWidth: 300)
        #expect(vm.readerWidth == WikiGraphViewModel.minReaderWidth)
    }
}
