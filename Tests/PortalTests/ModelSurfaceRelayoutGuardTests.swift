import Foundation
import Testing

/// Guards on the edits that broke a 100%-CPU relayout loop in the model
/// artifact surface (`ModelBlockView` + the Kanban board it embeds). Like
/// `CanvasRelayoutGuardTests`, these are structural properties of a SwiftUI
/// view body, so they are pinned by reading the source.
///
/// **The loop, as sampled from a live beachball on 2026-09-25.** The artifact
/// pane's `ScrollView` proposes an unbounded height to `ModelCard`, whose
/// `LazyVStack` (#537) placed a table view: a horizontal-only `ScrollView`
/// around a `VStack` around a second `LazyVStack` of rows. That inner lazy
/// stack can never skip a row — nothing scrolls vertically inside a horizontal
/// scroll view — so each pass it measured every row at an unbounded height
/// and, having no viewport to estimate against, re-armed itself:
///
/// ```
/// LazySubviewPlacements.placeSubviews → LazyStack.place → ForEach(views)
///   → ForEach(sets) → ScrollView(.horizontal) → VStack.sizeChildrenIdeally
///   → LazyLayoutComputer.Engine.sizeThatFits → LazyStack.measureEstimates
///   → LazyLayoutViewCache.signalPrefetch
///   → NSHostingView.requestUpdate(after:) → setNeedsUpdate  ← next pass
/// ```
///
/// Main thread 100% busy for 150 CPU-minutes, RSS flat: churn, not growth.
/// The Kanban columns (also `LazyVStack`s from #537, inside a fixed `HStack`
/// with no scroll viewport) sit on the same path and had already been caught
/// re-mounting cards on every tick (#594).
///
/// The rule these tests encode: a lazy stack only earns its keep as the direct
/// child of a scroll view that scrolls along its axis. Anywhere else it is
/// measured without a viewport and can only churn.
@Suite("Model surface relayout guards")
internal struct ModelSurfaceRelayoutGuardTests {

    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources/Portal")

    /// Source with `//` comment bodies removed, so a comment that names the
    /// wrong pattern while explaining the right one does not trip an
    /// absence check.
    private static func sourceWithoutComments(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sourcesRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let marker = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<marker.lowerBound])
        }
        .joined(separator: "\n")
    }

    @Test("The model card and its entity tables use no lazy stacks")
    internal func modelBlockViewHasNoLazyStacks() throws {
        let source = try Self.sourceWithoutComments("Views/Blocks/ModelBlockView.swift")
        #expect(
            !source.contains("LazyVStack") && !source.contains("LazyHStack"),
            """
            ModelBlockView must not use LazyVStack/LazyHStack. The card is \
            measured at an unbounded height by the artifact pane and by the \
            transcript, and the entity table's rows live in a horizontal-only \
            ScrollView; a lazy stack in either spot has no viewport, measures \
            every child, and re-arms layout via signalPrefetch → \
            NSHostingView.requestUpdate — a beachball at 100% CPU.
            """
        )
    }

    @Test("Kanban columns use no lazy stacks")
    internal func kanbanColumnsHaveNoLazyStacks() throws {
        let source = try Self.sourceWithoutComments("Views/Blocks/KanbanBlockView.swift")
        #expect(
            !source.contains("LazyVStack") && !source.contains("LazyHStack"),
            """
            KanbanBlockView must not use LazyVStack/LazyHStack. The board is a \
            fixed HStack of columns with no scroll viewport, so a lazy column \
            defers nothing and only re-arms the relayout loop (and re-mounted \
            every card per tick, #594). Large lanes are bounded by \
            KanbanDisplayPolicy.collapsedCardLimit instead.
            """
        )
    }

    @Test("Entity table rows index a once-sorted array")
    internal func entityTableSortsOncePerBody() throws {
        let source = try Self.sourceWithoutComments("Views/Blocks/ModelBlockView.swift")
        #expect(
            !source.contains("sortedItems["),
            """
            ModelEntityTable's row ForEach must index a local copy of \
            `sortedItems`, not the computed property: each access re-sorts the \
            whole entity set, which made a sorted table O(n² log n) per layout \
            pass.
            """
        )
    }
}
