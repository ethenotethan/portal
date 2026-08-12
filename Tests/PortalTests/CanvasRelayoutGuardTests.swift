import Foundation
import Testing

/// Guards on the two edits that broke a 100%-CPU relayout loop in the chat
/// canvas. Neither is expressible as pure math — both are structural properties
/// of a SwiftUI view body — so they are pinned by reading the source, the same
/// way `ArchitectureTests` pins invariants that regex linting can't reach.
///
/// **The loop, as sampled from a live 25-minute beachball.** The canvas is a
/// `GeometryReader` → `ZStack(alignment: .topLeading)` → `ForEach(panels)`, and
/// every panel is placed absolutely with `.position()`, so the container's
/// alignment contributes nothing to where a panel lands. SwiftUI resolves it
/// anyway, and resolving an alignment guide walks the child's whole layout:
///
/// ```
/// _ZStackLayout.sizeThatFits → ViewDimensions.subscript.getter
///   → explicitAlignment → UnaryLayoutEngine.childPlacement
///   → FrameLayoutCommon.commonPlacement → LayoutProxy.dimensions
///   → sizeThatFits → … (ScrollView → LazyVStack)
///   → LazyStack.measureEstimates → LazyLayoutViewCache.signalPrefetch
///   → NSHostingView.requestUpdate(after:) → setNeedsUpdate  ← next pass
/// ```
///
/// The last hop is what makes it a loop rather than one slow pass: measuring the
/// transcript at an unbounded (ideal) height enumerates every row, misses the
/// lazy stack's estimates, and *schedules another update*. The recursion was
/// ~170 frames deep, repeated at 100% CPU, with RSS flat — churn, not growth.
/// Two independent cuts close it, and each test below holds one:
///
///  1. constant alignment guides on the panel, so the container never queries
///     the subtree for a dimension and the descent never begins;
///  2. `minHeight: 0` on the transcript's scroll view, so an ideal-height query
///     is answered with 0 instead of the full content height.
///
/// Either alone stops the spin; both are kept because they fail independently
/// (a future panel could be laid out without `.position()`, and a future
/// ancestor could ask the transcript for its ideal height).
@Suite("Canvas relayout guards")
internal struct CanvasRelayoutGuardTests {

    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources/Portal")

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sourcesRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Canvas panels pin their alignment guides to a constant")
    internal func panelsPinAlignmentGuides() throws {
        let source = try Self.source("Views/ThoughtGraph/DashboardCanvasView.swift")
        // A closure that ignores its argument is the whole point: reading the
        // ViewDimensions parameter is what re-enters the child's layout.
        #expect(
            source.contains(".alignmentGuide(.leading) { _ in 0 }"),
            """
            DashboardCanvasView's panels must pin .leading to a constant. \
            Resolving the ZStack's .topLeading guide against a panel walks into \
            its content's sizeThatFits, which for the transcript panel reaches \
            LazyStack.measureEstimates → signalPrefetch → requestUpdate and \
            schedules the next pass — a relayout loop at 100% CPU. Panels are \
            positioned absolutely, so the guide's value is never used.
            """
        )
        #expect(
            source.contains(".alignmentGuide(.top) { _ in 0 }"),
            "Same as .leading above — .top must be pinned too, or the vertical guide alone restarts the descent."
        )
    }

    @Test("The canvas sizes itself from the reader, not from its panels")
    internal func canvasSizesFromGeometryReader() throws {
        let source = try Self.source("Views/ThoughtGraph/DashboardCanvasView.swift")
        #expect(
            source.contains("frame(width: geo.size.width, height: geo.size.height"),
            """
            The canvas ZStack must state its size from the GeometryReader. \
            Without it the container sizes from its children, putting panel \
            content back on the sizing path this fix removed it from.
            """
        )
    }

    @Test("The transcript scroll view answers an ideal-height query with zero")
    internal func transcriptDoesNotReportIdealContentHeight() throws {
        let source = try Self.source("Views/ThoughtGraph/ConversationPanel.swift")
        #expect(
            source.contains("frame(minHeight: 0, maxHeight: .infinity)"),
            """
            ConversationPanel's ScrollView needs minHeight: 0 alongside \
            maxHeight: .infinity. With only the flexible max, an ideal-height \
            query is answered with the full content height, and computing that \
            enumerates every row of the LazyVStack — the measurement that \
            triggers signalPrefetch and re-arms the relayout loop.
            """
        )
        // The flexible max is what fills the panel; losing it would trade a
        // beachball for a collapsed transcript.
        #expect(source.contains("maxHeight: .infinity"))
    }
}
