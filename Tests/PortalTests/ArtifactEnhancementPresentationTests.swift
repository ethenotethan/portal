import CoreGraphics
import Testing
@testable import Portal

@Suite("Artifact enhancement presentation policies")
internal struct ArtifactEnhancementPresentationTests {
    @Test("Kanban columns show a bounded preview until expanded")
    internal func kanbanColumnsBoundTheirPreview() throws {
        let cardsJSON = (1...12).map { index in
            "{\"id\":\"C\(index)\",\"title\":\"Card \(index)\",\"column\":\"Todo\"}"
        }.joined(separator: ",")
        let spec = try #require(KanbanSpec.parse("{\"columns\":[\"Todo\"],\"cards\":[\(cardsJSON)]}"))
        let cards = spec.cards(in: "Todo")

        #expect(KanbanDisplayPolicy.cardsToRender(cards, expanded: false).map(\.id) == (1...8).map { "C\($0)" })
        #expect(KanbanDisplayPolicy.hiddenCount(cardCount: cards.count, expanded: false) == 4)
        #expect(KanbanDisplayPolicy.cardsToRender(cards, expanded: true).count == 12)
        #expect(KanbanDisplayPolicy.hiddenCount(cardCount: cards.count, expanded: true) == 0)
    }

    @Test("Kanban ticket detail uses a readable bounded default size")
    internal func kanbanTicketDetailHasStableSize() {
        #expect(KanbanDisplayPolicy.ticketDetailSize == CGSize(width: 360, height: 420))
    }

    @Test("Model table columns use stable widths and center scalar values")
    internal func modelTableColumnsStayAligned() {
        let items = [
            ["issue_number": "10", "title": "A short title", "priority": "P2", "policy_valid": "1"],
            ["issue_number": "534", "title": "A much longer artifact enhancement title that must wrap", "priority": "P1", "policy_valid": "0"],
        ]
        let fields = ["issue_number", "title", "priority", "policy_valid"]

        let widths = ModelTableLayout.columnWidths(fields: fields, items: items, keyField: "issue_number")

        #expect(widths.count == fields.count)
        #expect(widths[1] > widths[0])
        #expect(ModelTableLayout.alignment(for: "title") == .leading)
        #expect(ModelTableLayout.alignment(for: "policy_valid") == .center)
        #expect(ModelTableLayout.tableWidth(widths: widths, showsActions: false) > widths.reduce(0, +))
    }

    @MainActor
    @Test("Interactive artifact graph selection synchronizes by entity id")
    internal func interactiveGraphSelectionSynchronizes() {
        let graph = WikiGraph(
            pages: [
                WikiPage(
                    id: "actors/worker", title: "Worker", type: "actors", tags: [],
                    path: "actors/worker", created: nil, updated: nil, confidence: nil,
                    contested: false, tagPath: ["actors"], integrationLinks: []
                ),
                WikiPage(
                    id: "state/queue", title: "Queue", type: "state", tags: [],
                    path: "state/queue", created: nil, updated: nil, confidence: nil,
                    contested: false, tagPath: ["state"], integrationLinks: []
                ),
            ],
            links: [WikiLink(source: "actors/worker", target: "state/queue", type: "writes")]
        )
        let viewModel = WikiGraphViewModel()
        viewModel.graph = graph
        viewModel.canvasSize = CGSize(width: 600, height: 320)
        viewModel.setupSimulation()

        InteractiveGraphSelection.apply("state/queue", to: viewModel)
        #expect(InteractiveGraphSelection.selectedID(in: viewModel) == "state/queue")

        InteractiveGraphSelection.apply(nil, to: viewModel)
        #expect(InteractiveGraphSelection.selectedID(in: viewModel) == nil)
    }
}
