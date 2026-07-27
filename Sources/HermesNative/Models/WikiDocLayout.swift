import CoreGraphics
import Foundation

/// One floating doc card on the wiki graph canvas: the page it shows, where it
/// sits, and its OWN back/forward history. Cards are independent — opening a
/// second node adds a second card, and each navigates its own history without
/// disturbing the others. That's why history lives here per-card rather than on
/// the view model's single shared selection plane (which still backs the graph
/// node highlight and the docked reader on iOS).
///
/// z-order is the card's position in `WikiDocLayout.cards` (last = frontmost),
/// so it needs no stored field of its own — the same convention the thought
/// dashboard uses.
internal struct WikiDocCard: Identifiable, Equatable {
    internal let id: UUID
    /// The page currently shown in this card.
    internal private(set) var path: String
    internal var frame: CGRect
    /// This card's own navigation history (paths), independent of every other
    /// card and of the shared selection plane.
    internal private(set) var backStack: [String]
    internal private(set) var forwardStack: [String]

    internal init(
        id: UUID = UUID(),
        path: String,
        frame: CGRect,
        backStack: [String] = [],
        forwardStack: [String] = []
    ) {
        self.id = id
        self.path = path
        self.frame = frame
        self.backStack = backStack
        self.forwardStack = forwardStack
    }

    internal var canGoBack: Bool { !backStack.isEmpty }
    internal var canGoForward: Bool { !forwardStack.isEmpty }

    /// Smallest a card may be shrunk to — keeps the header (back/forward/close)
    /// and content legible.
    internal static let minSize = CGSize(width: 260, height: 200)

    // MARK: Per-card navigation

    /// Navigate this card to `path`, pushing the current page onto its back
    /// stack and clearing forward. No-op when already showing `path`.
    internal mutating func navigate(to newPath: String) {
        guard newPath != path else { return }
        backStack.append(path)
        forwardStack.removeAll()
        path = newPath
    }

    internal mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
    }

    internal mutating func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
    }

    /// Return this card with its frame clamped so it stays at least partially
    /// on-canvas and no smaller than `minSize`. Used after a window resize.
    internal func clamped(to bounds: CGSize) -> WikiDocCard {
        var f = frame
        f.size.width = max(Self.minSize.width, min(f.size.width, bounds.width))
        f.size.height = max(Self.minSize.height, min(f.size.height, bounds.height))
        f.origin.x = min(max(0, f.origin.x), max(0, bounds.width - f.size.width))
        f.origin.y = min(max(0, f.origin.y), max(0, bounds.height - f.size.height))
        return WikiDocCard(
            id: id, path: path, frame: f,
            backStack: backStack, forwardStack: forwardStack
        )
    }
}

/// The set of floating doc cards over the wiki graph, ordered back-to-front
/// (`cards.last` draws on top and is the focused card). A pure value type so
/// its mutations (open, focus, navigate, resize, close) are unit-tested without
/// a running view.
internal struct WikiDocLayout: Equatable {
    internal private(set) var cards: [WikiDocCard]

    internal init(cards: [WikiDocCard] = []) {
        self.cards = cards
    }

    internal var isEmpty: Bool { cards.isEmpty }
    internal var frontCard: WikiDocCard? { cards.last }

    /// Cascade offset so each new card lands slightly down-right of the last,
    /// instead of stacking exactly on top and hiding it.
    private static let cascadeStep: CGFloat = 32
    internal static let defaultSize = CGSize(width: 420, height: 520)

    // MARK: Queries

    internal func card(withID id: UUID) -> WikiDocCard? {
        cards.first { $0.id == id }
    }

    /// The frontmost card currently showing `path`, if any. Used to focus an
    /// already-open page rather than opening a duplicate.
    internal func frontmostCard(showing path: String) -> WikiDocCard? {
        cards.last { $0.path == path }
    }

    // MARK: Mutation

    /// Open a card for `path`, or focus the existing one if already open, and
    /// return the affected card's id. A fresh card is placed cascaded from the
    /// current front card and centered-ish in `bounds` when there's room.
    @discardableResult
    internal mutating func openOrFocus(path: String, bounds: CGSize) -> UUID {
        if let existing = frontmostCard(showing: path) {
            bringToFront(existing.id)
            return existing.id
        }
        let frame = nextFrame(in: bounds)
        let card = WikiDocCard(path: path, frame: frame)
        cards.append(card)
        return card.id
    }

    /// Bring a card to the front (end of array) so it draws over its neighbors
    /// and takes the next drag. No-op if already frontmost or absent.
    internal mutating func bringToFront(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }), idx != cards.count - 1 else { return }
        let card = cards.remove(at: idx)
        cards.append(card)
    }

    internal mutating func remove(_ id: UUID) {
        cards.removeAll { $0.id == id }
    }

    internal mutating func removeAll() {
        cards.removeAll()
    }

    /// Replace a card's frame in place (after a drag or resize), preserving order.
    internal mutating func setFrame(_ frame: CGRect, for id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].frame = frame
    }

    internal mutating func navigate(_ id: UUID, to path: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].navigate(to: path)
    }

    internal mutating func goBack(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].goBack()
    }

    internal mutating func goForward(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[idx].goForward()
    }

    /// Clamp every card into the given canvas bounds (window resized).
    internal func clamped(to bounds: CGSize) -> WikiDocLayout {
        guard bounds.width > 0, bounds.height > 0 else { return self }
        return WikiDocLayout(cards: cards.map { $0.clamped(to: bounds) })
    }

    // MARK: Placement

    /// Where a newly-opened card should go: cascaded down-right from the front
    /// card, wrapping back toward the top-left when it would run off-canvas, and
    /// clamped so it always lands fully on the visible canvas.
    private func nextFrame(in bounds: CGSize) -> CGRect {
        let size = CGSize(
            width: min(Self.defaultSize.width, max(WikiDocCard.minSize.width, bounds.width)),
            height: min(Self.defaultSize.height, max(WikiDocCard.minSize.height, bounds.height))
        )
        let origin: CGPoint
        if let front = cards.last {
            var x = front.frame.minX + Self.cascadeStep
            var y = front.frame.minY + Self.cascadeStep
            if x + size.width > bounds.width { x = Self.cascadeStep }
            if y + size.height > bounds.height { y = Self.cascadeStep }
            origin = CGPoint(x: x, y: y)
        } else {
            // First card: roughly centered.
            origin = CGPoint(
                x: max(0, (bounds.width - size.width) / 2),
                y: max(0, (bounds.height - size.height) / 3)
            )
        }
        let clampedX = min(max(0, origin.x), max(0, bounds.width - size.width))
        let clampedY = min(max(0, origin.y), max(0, bounds.height - size.height))
        return CGRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }
}
