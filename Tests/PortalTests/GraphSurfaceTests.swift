import Testing
import Foundation
@testable import Portal

/// The Graphs section persists which of its two graphs you last had open, so the
/// raw values are a stored contract and the labels are the only thing a reader
/// has to tell the graphs apart. These tests pin both: a case whose raw value
/// drifts silently reopens the wrong graph (or none), and a switcher whose two
/// entries read alike is a dropdown nobody can use.
@Suite("Graph surface")
internal struct GraphSurfaceTests {

    // MARK: - The stored contract

    @Test("raw values are the persisted contract and must not drift")
    internal func rawValuesArePinned() {
        // Written to `@AppStorage("graphs.surface")`. Changing either string
        // silently reopens the default graph for everyone who had the other one
        // selected, which is exactly the kind of break no test would catch.
        #expect(GraphSurface.wiki.rawValue == "wiki")
        #expect(GraphSurface.runtime.rawValue == "runtime")
    }

    @Test("both graphs are offered, wiki first")
    internal func allCasesAreOrdered() {
        // Order is menu order. Wiki leads because it's the surface this door
        // used to open directly — the dropdown shouldn't relocate it.
        #expect(GraphSurface.allCases == [.wiki, .runtime])
    }

    @Test("id is the raw value, so ForEach identity survives a relabel")
    internal func identityIsRawValue() {
        for surface in GraphSurface.allCases {
            #expect(surface.id == surface.rawValue)
        }
    }

    // MARK: - Tolerant decode

    @Test("a stored value that isn't a known graph opens the wiki graph")
    internal func unknownStoredValueFallsBack() {
        // A downgrade, or a hand-edited defaults plist, must not leave the
        // section rendering nothing.
        #expect(GraphSurface.stored("runtime") == .runtime)
        #expect(GraphSurface.stored("wiki") == .wiki)
        #expect(GraphSurface.stored("") == .wiki)
        #expect(GraphSurface.stored("codegraph") == .wiki)
        #expect(GraphSurface.stored("Wiki") == .wiki) // case-sensitive by design
    }

    @Test("a round trip through the stored string is lossless")
    internal func storedRoundTripsEveryCase() {
        for surface in GraphSurface.allCases {
            #expect(GraphSurface.stored(surface.rawValue) == surface)
        }
    }

    @Test("Codable round-trips through the raw value")
    internal func codableRoundTrip() throws {
        for surface in GraphSurface.allCases {
            let encoded = try JSONEncoder().encode(surface)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(surface.rawValue)\"")
            #expect(try JSONDecoder().decode(GraphSurface.self, from: encoded) == surface)
        }
    }

    // MARK: - The dropdown has to be readable

    @Test("every graph has a distinct, non-empty label, summary, and glyph")
    internal func presentationIsDistinct() {
        let labels = GraphSurface.allCases.map(\.label)
        let summaries = GraphSurface.allCases.map(\.summary)
        let glyphs = GraphSurface.allCases.map(\.systemImage)

        for text in labels + summaries + glyphs {
            #expect(!text.isEmpty)
        }
        // Two entries that look the same are a dropdown that can't be used.
        #expect(Set(labels).count == GraphSurface.allCases.count)
        #expect(Set(summaries).count == GraphSurface.allCases.count)
        #expect(Set(glyphs).count == GraphSurface.allCases.count)
    }

    @Test("labels name the graph, not the door it used to live behind")
    internal func labelsNameTheGraph() {
        #expect(GraphSurface.wiki.label == "Wiki")
        #expect(GraphSurface.runtime.label == "Runtime graph")
        // The runtime graph came out of the Cron surface; its label must not
        // still say "Cron", which would read as a duplicate of that section.
        #expect(!GraphSurface.runtime.label.lowercased().contains("cron"))
    }

    @Test("the wiki glyph still matches the toolbar door that opens Graphs")
    internal func wikiGlyphMatchesToolbarSlot() {
        // The section is entered through the `wiki` toolbar slot; a mismatch here
        // means the dropdown shows a different icon than the button you pressed.
        #expect(GraphSurface.wiki.systemImage == ToolbarIconSlot.wiki.systemImage)
    }

    @Test("the graph switcher reserves its own top bar instead of overlaying graph controls")
    @MainActor
    internal func switcherReservesTopBar() {
        #expect(GraphsView.chromePlacement(offersSwitcher: true, reservesTopBar: true) == .reservedTopBar)
        #expect(GraphsView.chromePlacement(offersSwitcher: true, reservesTopBar: false) == .embedded)
        #expect(GraphsView.chromePlacement(offersSwitcher: false, reservesTopBar: true) == .none)
    }

    @Test("a runtime wiki resource resolves to its wiki page path")
    internal func runtimeWikiResourceResolvesToPagePath() {
        let node = CronGraphNode(
            id: "wiki:reports/daily",
            kind: "artifact",
            type: "wiki",
            label: "reports/daily",
            description: "",
            schedule: nil,
            enabled: true,
            usesLLM: false,
            lastStatus: nil,
            deliver: nil
        )

        #expect(node.wikiPagePath == "reports/daily.md")
    }

    @Test("opening a runtime wiki resource selects its page and the wiki surface")
    @MainActor
    internal func openingRuntimeWikiResourceSelectsPageAndSurface() {
        let node = CronGraphNode(
            id: "wiki:reports/daily",
            kind: "artifact",
            type: "wiki",
            label: "reports/daily",
            description: "",
            schedule: nil,
            enabled: true,
            usesLLM: false,
            lastStatus: nil,
            deliver: nil
        )
        let page = WikiPage(
            id: "daily",
            title: "Daily report",
            type: "report",
            tags: [],
            path: "reports/daily.md",
            created: nil,
            updated: nil,
            confidence: nil,
            contested: false,
            tagPath: [],
            integrationLinks: []
        )
        let wikiViewModel = WikiGraphViewModel()
        wikiViewModel.graph = WikiGraph(pages: [page], links: [])
        wikiViewModel.setupSimulation()

        let destination = GraphsView.openWikiResource(node, in: wikiViewModel)

        #expect(destination == .wiki)
        #expect(wikiViewModel.selectedPath == "reports/daily.md")
        #expect(wikiViewModel.showPageDetail)
        #expect(wikiViewModel.selectedPage?.id == "daily")
    }

    // MARK: - The door itself

    @Test("the toolbar slot reads as Graphs while keeping its stored raw value")
    internal func toolbarSlotRenamedButStable() {
        // Overrides are persisted per slot by raw value, so the case had to keep
        // its name when the label became "Graphs".
        #expect(ToolbarIconSlot.wiki.rawValue == "wiki")
        #expect(ToolbarIconSlot.wiki.label == "Graphs")
        #expect(ToolbarIconSlot.wiki.helpText.contains("wiki"))
        #expect(ToolbarIconSlot.wiki.helpText.contains("runtime"))
    }
}
