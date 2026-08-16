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
///
/// **The loop survived that first fix, and the reason is worth keeping.** A later
/// beachball, sampled on a build that provably carried both cuts above, showed
/// the same chain still running — because the descent needs no particular path.
/// *Any* ancestor that asks a subtree for a dimension restarts it, and the canvas
/// has a second `ZStack(alignment: .topLeading)` one level down, inside
/// `panelView`, wrapping the card. That one was never pinned. The surviving chain
/// terminated in the same `LazyStack.measureEstimates`, reached this time via
/// `card`'s own frames rather than the container's.
///
/// That episode also differed in kind: RSS climbed ~10 MB/sec to 6.5 GB with
/// 1.7M live `NSConcreteAttributedString` / `NSCompositeAppearance` and 3.4M
/// `NSTextFieldBezelConfiguration`, and `SelectionOverlay.updateNSView` (SwiftUI's
/// `textSelection` backing view) was newly on the hot path re-running
/// `-[NSControl setFont:]`. So the same runaway layout pass leaks when the
/// measured subtree contains selectable text, rather than merely churning.
///
/// The lesson the tests encode: pin EVERY alignment-resolving container on the
/// path, and count the pins rather than asserting one exists.
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

    /// `source` with `//` comment bodies removed.
    ///
    /// Needed for the guards that assert a construct is *absent*: the fix for a
    /// bug this subtle documents the wrong pattern by name right above the right
    /// one, so a plain `contains` check finds the explanation and fails on a file
    /// that is actually correct. (It did — on the very commit that added it.)
    /// Only the `//` form is stripped; nothing here uses `/* */`.
    private static func sourceWithoutComments(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
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

    @Test("The panel's own stack pins its alignment guides too")
    internal func panelStackPinsAlignmentGuides() throws {
        let source = try Self.source("Views/ThoughtGraph/DashboardCanvasView.swift")
        // There are TWO `ZStack(alignment: .topLeading)` in this file — the canvas
        // container in `body` and the per-panel layer stack in `panelView` — and
        // each resolves the guide against its own child. Pinning only the outer one
        // left the loop running on a build that shipped that fix: the surviving
        // sampled chain was _ZStackLayout.sizeThatFits → explicitAlignment →
        // childPlacement → _FrameLayout → … → LazyStack.measureEstimates, i.e. the
        // inner stack over `card`'s fixed frame. So count the pins, don't just
        // check that one exists.
        #expect(
            source.components(separatedBy: ".alignmentGuide(.leading) { _ in 0 }").count - 1 >= 2,
            """
            Both of DashboardCanvasView's .topLeading ZStacks must pin .leading — \
            the canvas container in `body` AND the per-panel layer stack in \
            `panelView`. Either one left unpinned restarts the alignment descent \
            into the panel's content and re-arms the relayout loop.
            """
        )
        #expect(
            source.components(separatedBy: ".alignmentGuide(.top) { _ in 0 }").count - 1 >= 2,
            "Same as .leading — both stacks need .top pinned, or the vertical guide alone restarts the descent."
        )
    }

    @Test("Panel content answers an ideal-height query with zero")
    internal func panelContentDoesNotReportIdealHeight() throws {
        let source = try Self.source("Views/ThoughtGraph/DashboardCanvasView.swift")
        // `card`'s content frame is on the sampled descent
        // (_FlexFrameLayout.sizeThatFits → ScrollViewLayoutComputer →
        // LazyStack.measureEstimates), so it needs the same minHeight: 0 that
        // ConversationPanel's scroll view carries. This guards every canvas at
        // once: all five DashboardCanvasView call sites share this frame.
        #expect(
            source.contains("minHeight: 0, maxHeight: .infinity"),
            """
            DashboardCanvasView's panel content frame needs minHeight: 0 alongside \
            maxHeight: .infinity. With only the flexible max, an ideal-height query \
            is answered with the full content height, and computing that enumerates \
            a hosted lazy stack — the measurement that re-arms the relayout loop.
            """
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

    // MARK: - The plain ChatView transcript
    //
    // The loop came back a THIRD time, and this is why: every guard above reads
    // a canvas file, but the sampled beachball had no canvas open at all. Zero
    // `ConversationPanel`, `DashboardCanvasView`, or `SessionChatCanvas` frames
    // appeared anywhere on the main thread — only `ChatMessage`,
    // `MessageBubbleView`, and `PortalProgressView`. `ChatView.messageListArea`
    // is a second, independent host of the same
    // `ScrollView → ZStack(.topLeading) → LazyVStack` shape, and it carried
    // neither cut. Same 100% CPU, same
    // `measureEstimates → signalPrefetch → requestUpdate → setNeedsUpdate`
    // chain, and the leaking variant again: RSS climbing ~4 MB/sec through
    // 3.1 GB with `SelectionOverlay.updateNSView` on the hot path.
    //
    // The lesson from the second recurrence was "count the pins, don't assert
    // one exists". The lesson from this one is that the pins must be counted on
    // every view that hosts the shape, not just the one that reported first.

    @Test("ChatView's transcript stack pins its alignment guides")
    internal func chatViewTranscriptPinsAlignmentGuides() throws {
        let source = try Self.source("Views/ChatView.swift")
        #expect(
            source.contains(".alignmentGuide(.leading) { _ in 0 }"),
            """
            ChatView's transcript ZStack(alignment: .topLeading) must pin \
            .leading to a constant. Resolving the guide against the transcript \
            descends into LazyStack.measureEstimates → signalPrefetch → \
            requestUpdate and schedules the next pass — the same 100%-CPU loop \
            fixed twice in the canvas, recurring here because this view hosts \
            the same shape and was never pinned.
            """
        )
        #expect(
            source.contains(".alignmentGuide(.top) { _ in 0 }"),
            "Same as .leading — the vertical guide alone restarts the descent."
        )
    }

    @Test("ChatView's transcript answers an ideal-height query with zero")
    internal func chatViewTranscriptDoesNotReportIdealHeight() throws {
        let source = try Self.source("Views/ChatView.swift")
        #expect(
            source.contains("frame(maxWidth: .infinity, minHeight: 0, alignment: .leading)"),
            """
            ChatView's transcript content frame needs minHeight: 0, the same cut \
            ConversationPanel's ScrollView carries. The sampled chain runs \
            sizeChildrenIdeally → LazyVStackLayout.sizeThatFits → \
            measureEstimates straight through this frame, so an ideal-height \
            query enumerates every message row and re-arms the loop.
            """
        )
    }

    @Test("ChatView's transcript SCROLL VIEW answers an ideal-height query with zero")
    internal func chatViewScrollViewDoesNotReportIdealHeight() throws {
        // The fourth recurrence, hours after the third. The content-side
        // minHeight above was in the shipping build and the loop returned
        // anyway (Wispr Flow dictation → Enter → 100% CPU, sampled live) —
        // because the descent entered one level HIGHER: the enclosing
        // ZStack(alignment: .bottom) resolves its guide against the
        // ScrollView itself, and that query proposes the ideal size to the
        // scroll view's own layout computer, which measures the full
        // transcript without ever consulting the content frame's minHeight.
        // The cut must sit on the ScrollView, exactly where ConversationPanel
        // has carried it since the first canvas fix.
        let source = try Self.source("Views/ChatView.swift")
        #expect(
            source.contains(".frame(minHeight: 0, maxHeight: .infinity)"),
            """
            ChatView's transcript ScrollView needs its own \
            frame(minHeight: 0, maxHeight: .infinity) — the content-side cut \
            cannot answer an ideal-size query addressed to the ScrollView. \
            Without it the .bottom-aligned overlay stack's guide resolution \
            enumerates every transcript row per pass at 100% CPU.
            """
        )
    }

    // MARK: - The transcript is eager

    @Test("the canvas transcript is eager, not lazy")
    internal func canvasTranscriptIsEager() throws {
        // The engine of the fifth beachball, after every entrance-pin above
        // held: LazyLayoutViewCache itself. Each pass runs updateItemPhases →
        // value_set → propagate_dirty (lldb's stop frame mid-spin), which
        // dirties the graph and schedules the next pass — with zero external
        // input (socket bytes frozen, no stream), the loop ran at 100% CPU
        // indefinitely. Layout pins can't fix that; they only close entrances.
        // The transcript must render an eager VStack over a bounded tail
        // window instead: no item phases, no prefetch, nothing to
        // self-schedule.
        let source = try Self.source("Views/ThoughtGraph/ConversationPanel.swift")
        #expect(
            !source.contains("LazyVStack("),
            """
            ConversationPanel must not host the transcript in a LazyVStack — \
            the lazy cache's phase updates are the self-scheduling engine of \
            the relayout loop. Eager over a bounded window (scrollWindowSize + \
            Show earlier) renders the same content without the machinery.
            """
        )
        #expect(
            source.contains("scrollWindowSize"),
            "Eager is only affordable windowed — the bounded tail must exist."
        )
    }

    // MARK: - Live-tail follow

    @Test("the live-tail follow is coalesced and unanimated")
    internal func liveTailFollowIsCoalescedAndUnanimated() throws {
        // The fifth recurrence, and the first that was NOT a layout-pin gap:
        // ConversationPanel followed the stream tail with a bare ANIMATED
        // scrollTo on every streamTailKey change (every 256 streamed chars).
        // Tens of overlapping 150ms animations per second, each resolving the
        // bottom anchor across the whole lazy transcript inside an animation
        // transaction — the animator never settles and the main thread pins at
        // 100% for the entire stream (Wispr dictation → Enter → beachball,
        // sampled live twice on one build). The follow must funnel through
        // followLiveTail, which batches to one UNANIMATED snap per 150ms.
        let source = try Self.source("Views/ThoughtGraph/ConversationPanel.swift")
        #expect(
            !source.contains("if showsLiveTail { scrollToBottom(proxy) }"),
            """
            ConversationPanel's stream-follow handlers must not call the \
            animated scrollToBottom directly — every 256 streamed characters \
            that starts another overlapping animation over the whole lazy \
            transcript, which is the 100%-CPU scroll storm.
            """
        )
        #expect(
            source.components(separatedBy: "followLiveTail(proxy)").count - 1 >= 2,
            "Both live-tail triggers (streamTailKey and messages.count) must funnel through followLiveTail."
        )
        #expect(
            source.contains("scrollToBottom(proxy, animated: false)"),
            "The coalesced follow must snap, not animate — the ease was always outrun by the next trigger."
        )
    }

    // MARK: - Widget flamechart fit

    @Test("the flamechart's live refit is gated on growth, not the host's isStreaming")
    internal func flamechartRefitsWheneverBarsGrow() throws {
        // Running bars grow toward `now` at draw time regardless of what the
        // host believes, so a refit gated on the host's `isStreaming` flag
        // breaks the moment any host wires it wrong — the canvas's Turns mode
        // passed `isStreaming: false` for the live turn, and the flamechart
        // crawled off the widget's right edge instead of shrinking to fit.
        let source = try Self.source("Views/ThoughtGraph/ThoughtGraphView.swift")
        #expect(
            !source.contains("guard isStreaming, !hasUserAdjustedCamera"),
            """
            advanceMotion's refit must not require the host's isStreaming — the \
            frames it already decided to produce (running bars, appear \
            animations) are the correct gate. Growth without refit overflows \
            the widget.
            """
        )
        #expect(
            source.contains("guard !hasUserAdjustedCamera, canvasSize.width > 0 else { return }"),
            "the refit still defers to manual camera control and needs a measured canvas"
        )
    }

    @Test("the canvas's Turns mode computes liveness instead of hardcoding settled")
    internal func turnsModeKnowsTheLiveTurn() throws {
        let source = try Self.source("Views/ThoughtGraph/SessionChatCanvas.swift")
        #expect(
            source.contains("turn.id == turns.last?.id"),
            """
            panelContext's Turns branch must ask whether the selected turn IS \
            the live one (newest turn while streaming — the same rule as \
            SessionThoughtGraphView.selectedTurnIsLive). Hardcoding \
            isStreaming: false told the flamechart a growing turn was settled.
            """
        )
        #expect(
            !source.contains("isThinking: false,\n                isStreaming: false,"),
            "the settled-turn hardcoding must not return"
        )
    }

    // MARK: - Spinner animation scope

    @Test("PortalProgressView scopes its repeatForever to one value")
    internal func progressViewDoesNotAnimateTheTransaction() throws {
        let source = try Self.sourceWithoutComments("Views/PortalProgressView.swift")
        // `withAnimation` applies the animation to the entire transaction, so
        // every change flushed alongside it inherits the curve. This curve is
        // `repeatForever` — it never completes — so an ancestor frame changing
        // in the same update animated forever and kept SwiftUI's animator
        // permanently scheduled, re-laying out the window every tick.
        // `AnimatableFrameAttribute.updateValue` and `AnimatorState.nextUpdate`
        // were both on the sampled hot path.
        //
        // This view is on screen during every stream (MessageBubbleView's
        // thinking trace and reasoning section, ChatView's transient status),
        // which is why the spin correlated with streaming.
        #expect(
            !source.contains("withAnimation"),
            """
            PortalProgressView must not drive its repeatForever spin with \
            withAnimation: that sets the animation on the whole transaction, so \
            an ancestor's frame change inherits a curve that never ends and the \
            animator never settles. Use .animation(_:value:), which is what the \
            app's other four repeatForever sites already do.
            """
        )
        #expect(
            source.contains(".animation("),
            "The spin still has to be animated — a scoped .animation(_:value:), not a dropped one."
        )
        #expect(source.contains("repeatForever"))
    }
}
