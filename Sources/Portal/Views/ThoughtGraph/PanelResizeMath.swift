import CoreGraphics

/// Which grip on a panel is being dragged during a resize. `.move` is the whole
/// panel (title-bar drag); the rest are the eight edge/corner handles.
internal enum PanelHandle: CaseIterable {
    case move
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Handles that change width from the left / top edge (origin moves with size).
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

/// Pure geometry for dragging and resizing a panel. Kept free of SwiftUI so the
/// interaction rules (min size, edge anchoring, canvas clamping) are unit-tested
/// directly instead of through a gesture. Every routine takes the frame the drag
/// STARTED from plus the cumulative translation, so it's idempotent per drag —
/// the view stores the start frame on drag-begin and recomputes from raw
/// translation each change, never accumulating rounding error.
internal enum PanelResizeMath {
    internal static let minSize = DashboardPanel.minSize

    /// Apply a drag `translation` to `startFrame` for the given `handle`,
    /// enforcing `minSize` and keeping the result within `bounds`.
    internal static func apply(
        handle: PanelHandle,
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

    /// Resolve a `candidate` frame against the other panels so no two panels
    /// ever overlap (the user's "strict boundary"). Rects that merely share an
    /// edge don't count as overlapping (`CGRect.intersects` treats a zero-area
    /// intersection as no intersection), so panels can sit flush.
    ///
    /// Only neighbours the panel does **not already overlap** can block it, so a
    /// layout that starts overlapping (an older saved arrangement, or a freshly
    /// added panel dropped on top of another) can always be dragged apart and is
    /// never frozen in place — we only ever prevent creating *new* overlap.
    ///
    /// - A **move** that would newly overlap slides along the obstacle: try the
    ///   horizontal component alone, then the vertical alone, else stay put — so
    ///   grazing a neighbour glides past it instead of sticking.
    /// - A **resize** that would newly overlap is rejected (returns `startFrame`),
    ///   so a panel stops growing at its neighbour's edge, not through it.
    internal static func resolveOverlap(
        candidate: CGRect,
        startFrame: CGRect,
        handle: PanelHandle,
        others: [CGRect]
    ) -> CGRect {
        let blockers = others.filter { !$0.intersects(startFrame) }
        func hits(_ rect: CGRect) -> Bool { blockers.contains { $0.intersects(rect) } }
        guard hits(candidate) else { return candidate }

        guard handle == .move else { return startFrame }

        let horizontalOnly = CGRect(
            x: candidate.minX, y: startFrame.minY,
            width: candidate.width, height: candidate.height
        )
        if !hits(horizontalOnly) { return horizontalOnly }

        let verticalOnly = CGRect(
            x: startFrame.minX, y: candidate.minY,
            width: candidate.width, height: candidate.height
        )
        if !hits(verticalOnly) { return verticalOnly }

        return startFrame
    }

    /// Snap a `frame`'s active edges to nearby alignment lines so panels sit
    /// flush instead of a few pixels apart. Targets are the canvas walls (0 and
    /// `bounds`) plus every neighbour's four edges. Within `threshold` points the
    /// nearest target wins; beyond it the frame is untouched.
    ///
    /// - A **move** snaps as a whole: the smallest snap offset on each axis is
    ///   applied to the origin (size preserved), so a dragged panel clicks onto a
    ///   wall or a neighbour's edge.
    /// - A **resize** snaps only the dragged edge(s), so growing a panel latches
    ///   onto the neighbour it's approaching.
    ///
    /// Snapping runs BEFORE overlap resolution, so a snap that would cause overlap
    /// is still corrected by `resolveOverlap`.
    internal static func snap(
        frame: CGRect,
        handle: PanelHandle,
        others: [CGRect],
        bounds: CGSize,
        threshold: CGFloat = 8
    ) -> CGRect {
        let xLines = alignmentLines(others: others, bounds: bounds, vertical: true)
        let yLines = alignmentLines(others: others, bounds: bounds, vertical: false)

        if handle == .move {
            let dx = nearestOffset(for: [frame.minX, frame.maxX], lines: xLines, threshold: threshold)
            let dy = nearestOffset(for: [frame.minY, frame.maxY], lines: yLines, threshold: threshold)
            return frame.offsetBy(dx: dx, dy: dy)
        }

        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        if handle.movesLeadingEdge, let s = nearestLine(to: minX, lines: xLines, threshold: threshold) {
            minX = min(s, maxX - minSize.width)
        }
        if handle.movesTrailingEdge, let s = nearestLine(to: maxX, lines: xLines, threshold: threshold) {
            maxX = max(s, minX + minSize.width)
        }
        if handle.movesTopEdge, let s = nearestLine(to: minY, lines: yLines, threshold: threshold) {
            minY = min(s, maxY - minSize.height)
        }
        if handle.movesBottomEdge, let s = nearestLine(to: maxY, lines: yLines, threshold: threshold) {
            maxY = max(s, minY + minSize.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Candidate snap lines on one axis: the two canvas walls plus each other
    /// panel's near/far edges on that axis.
    private static func alignmentLines(others: [CGRect], bounds: CGSize, vertical: Bool) -> [CGFloat] {
        var lines: [CGFloat] = [0, vertical ? bounds.width : bounds.height]
        for r in others {
            lines.append(vertical ? r.minX : r.minY)
            lines.append(vertical ? r.maxX : r.maxY)
        }
        return lines
    }

    /// The nearest line to `value` within `threshold`, or nil if none is close.
    private static func nearestLine(to value: CGFloat, lines: [CGFloat], threshold: CGFloat) -> CGFloat? {
        lines.filter { abs($0 - value) <= threshold }.min { abs($0 - value) < abs($1 - value) }
    }

    /// The signed offset that best snaps ANY of `values` (a frame's two edges on
    /// one axis) onto a line — the smallest-magnitude qualifying snap, else 0.
    private static func nearestOffset(for values: [CGFloat], lines: [CGFloat], threshold: CGFloat) -> CGFloat {
        var best: CGFloat = 0
        var bestMag = threshold + 1
        for value in values {
            for line in lines {
                let delta = line - value
                if abs(delta) <= threshold && abs(delta) < bestMag {
                    best = delta
                    bestMag = abs(delta)
                }
            }
        }
        return best
    }

    /// Find a spot for a newly-added panel of `size` that doesn't overlap any of
    /// `others`, scanning a coarse grid across `bounds` (row-major from the top-
    /// left). Falls back to the top-left corner if the canvas is already full —
    /// resolveOverlap then lets the user drag it out, so a full canvas is
    /// recoverable rather than blocking the add.
    internal static func vacantSlot(size: CGSize, others: [CGRect], bounds: CGSize) -> CGRect {
        let step: CGFloat = 24
        let maxX = max(0, bounds.width - size.width)
        let maxY = max(0, bounds.height - size.height)
        var y: CGFloat = 0
        while y <= maxY {
            var x: CGFloat = 0
            while x <= maxX {
                let candidate = CGRect(x: x, y: y, width: size.width, height: size.height)
                if !others.contains(where: { $0.intersects(candidate) }) { return candidate }
                x += step
            }
            y += step
        }
        return CGRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// Settle a just-dropped `desired` frame onto the non-overlapping spot
    /// closest to where the user released it. If the drop is already clear it's
    /// returned untouched (a drop in empty space stays exactly where it lands);
    /// otherwise a coarse grid is scanned and the free cell whose origin is
    /// nearest the drop wins — so a panel dragged over its neighbours settles
    /// beside them rather than snapping to a far corner. This is what lets a
    /// boxed-in panel be dragged freely across others and land in open space:
    /// the drag itself never resolves overlap, only this release step does.
    internal static func nearestVacant(to desired: CGRect, others: [CGRect], bounds: CGSize) -> CGRect {
        func clear(_ rect: CGRect) -> Bool { !others.contains { $0.intersects(rect) } }
        let inBounds = desired.minX >= 0 && desired.minY >= 0
            && desired.maxX <= bounds.width + 0.5 && desired.maxY <= bounds.height + 0.5
        if inBounds && clear(desired) { return desired }

        let step: CGFloat = 24
        let maxX = max(0, bounds.width - desired.width)
        let maxY = max(0, bounds.height - desired.height)
        var best: CGRect?
        var bestDist = CGFloat.greatestFiniteMagnitude
        var y: CGFloat = 0
        while y <= maxY {
            var x: CGFloat = 0
            while x <= maxX {
                let candidate = CGRect(x: x, y: y, width: desired.width, height: desired.height)
                if clear(candidate) {
                    let dx = x - desired.minX, dy = y - desired.minY
                    let dist = dx * dx + dy * dy
                    if dist < bestDist { bestDist = dist; best = candidate }
                }
                x += step
            }
            y += step
        }
        return best ?? CGRect(origin: .zero, size: desired.size)
    }

    // MARK: Auto-fill resize

    /// The outcome of an auto-fill resize: the resized panel's own frame (capped
    /// so it never pushes a flush neighbour below its minimum, nor grows through
    /// a non-adjacent neighbour) plus replacement frames for the flush neighbours
    /// that tracked the moved edge, keyed by their index in the `others` array.
    internal struct AutoFillResize: Equatable {
        internal let frame: CGRect
        internal let neighbours: [Int: CGRect]
    }

    /// Resize with neighbours that fill in: a panel edge dragged toward a flush
    /// neighbour pushes it (shrinking it, down to its minimum); dragged away, the
    /// flush neighbour's near edge follows into the vacated space (growing it). So
    /// shrinking a panel lets the others expand around it and growing it reclaims
    /// their space — the intuitive "tile" behaviour, instead of a resize that
    /// simply stops dead at a neighbour.
    ///
    /// A neighbour is *flush* on a moved edge when its opposite edge sits on that
    /// edge (within `flushTolerance`) AND it overlaps the panel on the other axis.
    /// A non-adjacent neighbour on the growth side is a hard wall (the panel stops
    /// at it), preserving the strict no-overlap rule for panels that aren't
    /// touching. Pure geometry — the gesture applies `frame` to the dragged panel
    /// and each `neighbours` entry to the corresponding other panel.
    internal static func autoFillResize(
        candidate: CGRect,
        startFrame: CGRect,
        handle: PanelHandle,
        others: [CGRect],
        bounds: CGSize,
        flushTolerance: CGFloat = 1.5
    ) -> AutoFillResize {
        // swiftlint:disable function_body_length cyclomatic_complexity
        var frame = candidate
        var updates: [Int: CGRect] = [:]

        // Cross-axis overlap tests against the panel's ORIGINAL extent, so a
        // neighbour only counts if it actually shares the dragged edge's span.
        func sharesRows(_ r: CGRect) -> Bool { r.minY < startFrame.maxY - 0.5 && r.maxY > startFrame.minY + 0.5 }
        func sharesCols(_ r: CGRect) -> Bool { r.minX < startFrame.maxX - 0.5 && r.maxX > startFrame.minX + 0.5 }

        if handle.movesTrailingEdge {
            var cap = bounds.width
            var flush: [Int] = []
            for (i, r) in others.enumerated() where sharesRows(r) {
                if abs(r.minX - startFrame.maxX) <= flushTolerance {
                    flush.append(i)
                    cap = min(cap, r.maxX - minSize.width)     // shrink neighbour, not past min
                } else if r.minX >= startFrame.maxX - flushTolerance {
                    cap = min(cap, r.minX)                       // non-adjacent → hard wall
                }
            }
            let newMaxX = min(frame.maxX, max(cap, frame.minX + minSize.width))
            frame = CGRect(x: frame.minX, y: frame.minY, width: newMaxX - frame.minX, height: frame.height)
            for i in flush {
                let r = others[i]
                let newMinX = min(newMaxX, r.maxX - minSize.width)
                updates[i] = CGRect(x: newMinX, y: r.minY, width: r.maxX - newMinX, height: r.height)
            }
        }

        if handle.movesLeadingEdge {
            var cap: CGFloat = 0
            var flush: [Int] = []
            for (i, r) in others.enumerated() where sharesRows(r) {
                if abs(r.maxX - startFrame.minX) <= flushTolerance {
                    flush.append(i)
                    cap = max(cap, r.minX + minSize.width)
                } else if r.maxX <= startFrame.minX + flushTolerance {
                    cap = max(cap, r.maxX)
                }
            }
            let newMinX = max(frame.minX, min(cap, frame.maxX - minSize.width))
            frame = CGRect(x: newMinX, y: frame.minY, width: frame.maxX - newMinX, height: frame.height)
            for i in flush {
                let r = others[i]
                let newMaxX = max(newMinX, r.minX + minSize.width)
                updates[i] = CGRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: r.height)
            }
        }

        if handle.movesBottomEdge {
            var cap = bounds.height
            var flush: [Int] = []
            for (i, r) in others.enumerated() where sharesCols(r) {
                if abs(r.minY - startFrame.maxY) <= flushTolerance {
                    flush.append(i)
                    cap = min(cap, r.maxY - minSize.height)
                } else if r.minY >= startFrame.maxY - flushTolerance {
                    cap = min(cap, r.minY)
                }
            }
            let newMaxY = min(frame.maxY, max(cap, frame.minY + minSize.height))
            frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: newMaxY - frame.minY)
            for i in flush {
                let r = others[i]
                let newMinY = min(newMaxY, r.maxY - minSize.height)
                updates[i] = CGRect(x: r.minX, y: newMinY, width: r.width, height: r.maxY - newMinY)
            }
        }

        if handle.movesTopEdge {
            var cap: CGFloat = 0
            var flush: [Int] = []
            for (i, r) in others.enumerated() where sharesCols(r) {
                if abs(r.maxY - startFrame.minY) <= flushTolerance {
                    flush.append(i)
                    cap = max(cap, r.minY + minSize.height)
                } else if r.maxY <= startFrame.minY + flushTolerance {
                    cap = max(cap, r.maxY)
                }
            }
            let newMinY = max(frame.minY, min(cap, frame.maxY - minSize.height))
            frame = CGRect(x: frame.minX, y: newMinY, width: frame.width, height: frame.maxY - newMinY)
            for i in flush {
                let r = others[i]
                let newMaxY = max(newMinY, r.minY + minSize.height)
                updates[i] = CGRect(x: r.minX, y: r.minY, width: r.width, height: newMaxY - r.minY)
            }
        }

        return AutoFillResize(frame: frame, neighbours: updates)
        // swiftlint:enable function_body_length cyclomatic_complexity
    }

    // MARK: Move

    private static func move(_ frame: CGRect, by t: CGSize, bounds: CGSize) -> CGRect {
        var f = frame
        f.origin.x += t.width
        f.origin.y += t.height
        // Clamp so the panel stays fully on-canvas (when it fits).
        let maxX = max(0, bounds.width - f.size.width)
        let maxY = max(0, bounds.height - f.size.height)
        f.origin.x = min(max(0, f.origin.x), maxX)
        f.origin.y = min(max(0, f.origin.y), maxY)
        return f
    }

    // MARK: Resize

    // swiftlint:disable:next function_body_length
    private static func resize(_ frame: CGRect, handle: PanelHandle, by t: CGSize, bounds: CGSize) -> CGRect {
        var minX = frame.minX
        var minY = frame.minY
        var maxX = frame.maxX
        var maxY = frame.maxY

        if handle.movesLeadingEdge {
            // Drag left edge; clamp so width never drops below min and edge stays >= 0.
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
