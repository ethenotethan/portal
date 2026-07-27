import CoreGraphics
import Testing
@testable import HermesNative

// The floating doc cards are backed by two pure value types — WikiDocLayout
// (which cards exist, in what z-order) and WikiDocResizeMath (drag/resize
// geometry). Both are exercised directly here so the interaction rules (open
// vs. focus, per-card history independence, min size, on-canvas clamping) are
// verified without a running view.
@Suite("Wiki floating doc cards")
internal struct WikiDocLayoutTests {

    private let bounds = CGSize(width: 1000, height: 800)

    // MARK: - Open / focus / z-order

    @Test("Opening two different pages yields two cards, front-most last")
    internal func openTwoCards() {
        var layout = WikiDocLayout()
        layout.openOrFocus(path: "a.md", bounds: bounds)
        layout.openOrFocus(path: "b.md", bounds: bounds)
        #expect(layout.cards.count == 2)
        #expect(layout.frontCard?.path == "b.md")
    }

    @Test("Opening an already-open page focuses it instead of duplicating")
    internal func openExistingFocuses() {
        var layout = WikiDocLayout()
        let idA = layout.openOrFocus(path: "a.md", bounds: bounds)
        layout.openOrFocus(path: "b.md", bounds: bounds)
        #expect(layout.frontCard?.path == "b.md")

        let refocused = layout.openOrFocus(path: "a.md", bounds: bounds)
        #expect(layout.cards.count == 2, "no duplicate card for an already-open page")
        #expect(refocused == idA, "focus returns the existing card's id")
        #expect(layout.frontCard?.id == idA)
        #expect(layout.frontCard?.path == "a.md")
    }

    @Test("bringToFront raises a background card; front is a no-op")
    internal func bringToFront() {
        var layout = WikiDocLayout()
        let idA = layout.openOrFocus(path: "a.md", bounds: bounds)
        let idB = layout.openOrFocus(path: "b.md", bounds: bounds)
        layout.bringToFront(idA)
        #expect(layout.frontCard?.id == idA)
        // Already front → order unchanged.
        layout.bringToFront(idA)
        #expect(layout.cards.map(\.id) == [idB, idA])
    }

    @Test("Removing the front card falls back to the next; removing all empties")
    internal func removeCards() {
        var layout = WikiDocLayout()
        let idA = layout.openOrFocus(path: "a.md", bounds: bounds)
        let idB = layout.openOrFocus(path: "b.md", bounds: bounds)
        layout.remove(idB)
        #expect(layout.frontCard?.id == idA)
        layout.remove(idA)
        #expect(layout.isEmpty)
    }

    // MARK: - Per-card history independence

    @Test("Each card navigates its own history; other cards are untouched")
    internal func perCardHistoryIsolated() {
        var layout = WikiDocLayout()
        let idA = layout.openOrFocus(path: "a1.md", bounds: bounds)
        let idB = layout.openOrFocus(path: "b1.md", bounds: bounds)

        layout.navigate(idA, to: "a2.md")
        // Card B is not affected by A's navigation.
        #expect(layout.card(withID: idA)?.path == "a2.md")
        #expect(layout.card(withID: idB)?.path == "b1.md")
        #expect(layout.card(withID: idA)?.canGoBack == true)
        #expect(layout.card(withID: idB)?.canGoBack == false)

        layout.goBack(idA)
        #expect(layout.card(withID: idA)?.path == "a1.md")
        #expect(layout.card(withID: idA)?.canGoForward == true)
        layout.goForward(idA)
        #expect(layout.card(withID: idA)?.path == "a2.md")
    }

    @Test("Navigating to the current path is a history no-op")
    internal func navigateSamePathNoop() {
        var card = WikiDocCard(path: "a.md", frame: .zero)
        card.navigate(to: "a.md")
        #expect(!card.canGoBack)
    }

    @Test("A fresh navigation clears the forward stack")
    internal func navigateClearsForward() {
        var card = WikiDocCard(path: "a.md", frame: .zero)
        card.navigate(to: "b.md")
        card.goBack()               // now at a.md, forward = [b.md]
        #expect(card.canGoForward)
        card.navigate(to: "c.md")   // fresh nav
        #expect(!card.canGoForward)
    }

    // MARK: - Placement & clamping

    @Test("A second card cascades off the first, not stacked exactly on it")
    internal func secondCardCascades() {
        var layout = WikiDocLayout()
        layout.openOrFocus(path: "a.md", bounds: bounds)
        let first = layout.frontCard?.frame.origin
        layout.openOrFocus(path: "b.md", bounds: bounds)
        let second = layout.frontCard?.frame.origin
        #expect(first != nil)
        #expect(second != first)
    }

    @Test("Every opened card lands fully on-canvas")
    internal func cardsStayOnCanvas() {
        var layout = WikiDocLayout()
        // Open enough cards to force the cascade to wrap.
        for i in 0..<12 {
            layout.openOrFocus(path: "p\(i).md", bounds: bounds)
        }
        for card in layout.cards {
            #expect(card.frame.minX >= 0)
            #expect(card.frame.minY >= 0)
            #expect(card.frame.maxX <= bounds.width + 0.001)
            #expect(card.frame.maxY <= bounds.height + 0.001)
        }
    }

    @Test("Clamp shrinks and repositions cards for a smaller canvas")
    internal func clampToSmallerBounds() {
        var layout = WikiDocLayout()
        layout.openOrFocus(path: "a.md", bounds: bounds)
        let small = CGSize(width: 300, height: 260)
        let clamped = layout.clamped(to: small)
        guard let card = clamped.frontCard else {
            Issue.record("expected a card after clamping")
            return
        }
        #expect(card.frame.width <= small.width + 0.001)
        #expect(card.frame.height <= small.height + 0.001)
        #expect(card.frame.maxX <= small.width + 0.001)
        #expect(card.frame.maxY <= small.height + 0.001)
        // Clamping preserves the page/history.
        #expect(card.path == "a.md")
    }

    // MARK: - Resize geometry

    private let startFrame = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test("Move drags the whole card by the translation")
    internal func moveTranslates() {
        let moved = WikiDocResizeMath.apply(
            handle: .move, startFrame: startFrame,
            translation: CGSize(width: 40, height: -30), bounds: bounds
        )
        #expect(moved.origin == CGPoint(x: 140, y: 70))
        #expect(moved.size == startFrame.size)
    }

    @Test("Move clamps the card to stay on-canvas")
    internal func moveClamps() {
        let moved = WikiDocResizeMath.apply(
            handle: .move, startFrame: startFrame,
            translation: CGSize(width: -500, height: -500), bounds: bounds
        )
        #expect(moved.origin == .zero)
    }

    @Test("Trailing/bottom resize grows the card from the far edge")
    internal func resizeTrailingBottom() {
        let resized = WikiDocResizeMath.apply(
            handle: .bottomTrailing, startFrame: startFrame,
            translation: CGSize(width: 60, height: 50), bounds: bounds
        )
        #expect(resized.origin == startFrame.origin) // near corner fixed
        #expect(resized.width == 460)
        #expect(resized.height == 350)
    }

    @Test("A resize never shrinks below the minimum size")
    internal func resizeRespectsMinSize() {
        let resized = WikiDocResizeMath.apply(
            handle: .bottomTrailing, startFrame: startFrame,
            translation: CGSize(width: -1000, height: -1000), bounds: bounds
        )
        #expect(resized.width == WikiDocCard.minSize.width)
        #expect(resized.height == WikiDocCard.minSize.height)
    }

    @Test("Leading/top resize moves the near edge and never leaves the canvas")
    internal func resizeLeadingTopClamps() {
        let resized = WikiDocResizeMath.apply(
            handle: .topLeading, startFrame: startFrame,
            translation: CGSize(width: -1000, height: -1000), bounds: bounds
        )
        #expect(resized.minX >= 0)
        #expect(resized.minY >= 0)
    }
}
