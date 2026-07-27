import CoreGraphics

/// Which grip on a floating doc card is being dragged. `.move` is the whole
/// card (title-bar drag); the rest are the eight edge/corner resize handles.
///
/// This mirrors the thought-dashboard's `PanelHandle`/`PanelResizeMath`, but is
/// deliberately its OWN copy: that machinery lives on an unmerged branch, and
/// the wiki feature ships independently. The math is ~90 lines of pure
/// geometry; duplicating it keeps this PR unblocked. If the two converge later,
/// promote one copy to a shared Utilities type and delete the other.
internal enum WikiDocHandle: CaseIterable {
    case move
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    internal var movesLeadingEdge: Bool {
        switch self {
        case .leading, .topLeading, .bottomLeading: return true
        default: return false
        }
    }

    internal var movesTopEdge: Bool {
        switch self {
        case .top, .topLeading, .topTrailing: return true
        default: return false
        }
    }

    internal var movesTrailingEdge: Bool {
        switch self {
        case .trailing, .topTrailing, .bottomTrailing: return true
        default: return false
        }
    }

    internal var movesBottomEdge: Bool {
        switch self {
        case .bottom, .bottomLeading, .bottomTrailing: return true
        default: return false
        }
    }
}

/// Pure geometry for dragging and resizing a floating doc card. Kept free of
/// SwiftUI so the interaction rules (min size, edge anchoring, canvas clamping)
/// are unit-tested directly. Every routine takes the frame the drag STARTED
/// from plus the cumulative translation, so it's idempotent per drag — the view
/// stores the start frame on drag-begin and recomputes from raw translation on
/// each change, never accumulating rounding error.
internal enum WikiDocResizeMath {
    internal static let minSize = WikiDocCard.minSize

    /// Apply a drag `translation` to `startFrame` for the given `handle`,
    /// enforcing `minSize` and keeping the result within `bounds`.
    internal static func apply(
        handle: WikiDocHandle,
        startFrame: CGRect,
        translation: CGSize,
        bounds: CGSize
    ) -> CGRect {
        switch handle {
        case .move:
            return move(startFrame, by: translation, bounds: bounds)
        default:
            return resize(startFrame, handle: handle, by: translation, bounds: bounds)
        }
    }

    private static func move(_ frame: CGRect, by t: CGSize, bounds: CGSize) -> CGRect {
        var f = frame
        f.origin.x += t.width
        f.origin.y += t.height
        let maxX = max(0, bounds.width - f.size.width)
        let maxY = max(0, bounds.height - f.size.height)
        f.origin.x = min(max(0, f.origin.x), maxX)
        f.origin.y = min(max(0, f.origin.y), maxY)
        return f
    }

    // swiftlint:disable:next function_body_length
    private static func resize(_ frame: CGRect, handle: WikiDocHandle, by t: CGSize, bounds: CGSize) -> CGRect {
        var minX = frame.minX
        var minY = frame.minY
        var maxX = frame.maxX
        var maxY = frame.maxY

        if handle.movesLeadingEdge {
            minX = min(minX + t.width, maxX - minSize.width)
            minX = max(0, minX)
        }
        if handle.movesTrailingEdge {
            maxX = max(maxX + t.width, minX + minSize.width)
            maxX = min(bounds.width, maxX)
        }
        if handle.movesTopEdge {
            minY = min(minY + t.height, maxY - minSize.height)
            minY = max(0, minY)
        }
        if handle.movesBottomEdge {
            maxY = max(maxY + t.height, minY + minSize.height)
            maxY = min(bounds.height, maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
