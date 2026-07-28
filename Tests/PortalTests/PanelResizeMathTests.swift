import CoreGraphics
import Testing
@testable import HermesNative

@Suite("Panel resize math")
internal struct PanelResizeMathTests {
    private let bounds = CGSize(width: 1000, height: 800)
    private let start = CGRect(x: 100, y: 100, width: 400, height: 300)

    // MARK: - Move

    @Test("Move translates the origin and preserves size")
    internal func moveTranslates() {
        let moved = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: 50, height: -30), bounds: bounds
        )
        #expect(moved.origin == CGPoint(x: 150, y: 70))
        #expect(moved.size == start.size)
    }

    @Test("Move clamps the panel fully on-canvas")
    internal func moveClampsToBounds() {
        // Drag hard past the top-left: origin pins at 0,0.
        let topLeft = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: -9999, height: -9999), bounds: bounds
        )
        #expect(topLeft.origin == .zero)

        // Drag hard past the bottom-right: the far edges stop at the bounds.
        let bottomRight = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: 9999, height: 9999), bounds: bounds
        )
        #expect(bottomRight.maxX == bounds.width)
        #expect(bottomRight.maxY == bounds.height)
        #expect(bottomRight.size == start.size)
    }

    // MARK: - Resize: trailing / bottom (far edges grow)

    @Test("Trailing resize grows width, anchored on the left edge")
    internal func trailingResize() {
        let r = PanelResizeMath.apply(
            handle: .trailing, startFrame: start, translation: CGSize(width: 120, height: 0), bounds: bounds
        )
        #expect(r.minX == start.minX)      // left edge fixed
        #expect(r.width == 520)
        #expect(r.height == start.height)  // vertical untouched
    }

    @Test("Bottom-trailing corner grows both dimensions from the top-left anchor")
    internal func bottomTrailingCorner() {
        let r = PanelResizeMath.apply(
            handle: .bottomTrailing, startFrame: start, translation: CGSize(width: 100, height: 80), bounds: bounds
        )
        #expect(r.origin == start.origin)
        #expect(r.width == 500)
        #expect(r.height == 380)
    }

    // MARK: - Resize: leading / top (near edges move, anchoring the far edge)

    @Test("Leading resize moves the left edge while pinning the right edge")
    internal func leadingResizePinsRightEdge() {
        let r = PanelResizeMath.apply(
            handle: .leading, startFrame: start, translation: CGSize(width: 60, height: 0), bounds: bounds
        )
        #expect(r.maxX == start.maxX)  // right edge fixed
        #expect(r.minX == 160)
        #expect(r.width == 340)
    }

    @Test("Top resize moves the top edge while pinning the bottom edge")
    internal func topResizePinsBottomEdge() {
        let r = PanelResizeMath.apply(
            handle: .top, startFrame: start, translation: CGSize(width: 0, height: -40), bounds: bounds
        )
        #expect(r.maxY == start.maxY)  // bottom edge fixed
        #expect(r.minY == 60)
        #expect(r.height == 340)
    }

    // MARK: - Minimum size

    @Test("Resize never shrinks below the minimum size")
    internal func minimumSizeEnforced() {
        // Collapse from the trailing edge far past zero width.
        let collapsed = PanelResizeMath.apply(
            handle: .trailing, startFrame: start, translation: CGSize(width: -9999, height: 0), bounds: bounds
        )
        #expect(collapsed.width == DashboardPanel.minSize.width)
        #expect(collapsed.minX == start.minX)  // still anchored left

        // Collapse from the leading edge: min size holds, right edge stays pinned.
        let collapsedLeading = PanelResizeMath.apply(
            handle: .leading, startFrame: start, translation: CGSize(width: 9999, height: 0), bounds: bounds
        )
        #expect(collapsedLeading.width == DashboardPanel.minSize.width)
        #expect(collapsedLeading.maxX == start.maxX)
    }

    // MARK: - Resize clamps to canvas

    @Test("Trailing resize can't grow past the right edge of the canvas")
    internal func resizeClampsToBounds() {
        let r = PanelResizeMath.apply(
            handle: .trailing, startFrame: start, translation: CGSize(width: 9999, height: 0), bounds: bounds
        )
        #expect(r.maxX == bounds.width)
    }

    // MARK: - Idempotence from a fixed start frame

    @Test("Applying the same translation from the same start frame is stable")
    internal func idempotentFromStart() {
        let t = CGSize(width: 33, height: 21)
        let a = PanelResizeMath.apply(handle: .bottomTrailing, startFrame: start, translation: t, bounds: bounds)
        let b = PanelResizeMath.apply(handle: .bottomTrailing, startFrame: start, translation: t, bounds: bounds)
        #expect(a == b)
    }

    // MARK: - No-overlap resolution

    @Test("A move into clear space is unchanged")
    internal func moveIntoClearSpaceUnchanged() {
        let candidate = CGRect(x: 200, y: 200, width: 400, height: 300)
        let other = CGRect(x: 700, y: 0, width: 200, height: 200)
        let resolved = PanelResizeMath.resolveOverlap(
            candidate: candidate, startFrame: start, handle: .move, others: [other]
        )
        #expect(resolved == candidate)
    }

    @Test("A move that would overlap slides along the obstacle on the free axis")
    internal func moveSlidesAlongObstacle() {
        // start at (100,100,400x300); an obstacle sits directly to the right.
        let obstacle = CGRect(x: 520, y: 100, width: 200, height: 300)
        // Try to move right+down into it. Horizontal component collides, but the
        // vertical-only move is clear, so it should take the vertical slide.
        let candidate = CGRect(x: 200, y: 250, width: 400, height: 300)
        let resolved = PanelResizeMath.resolveOverlap(
            candidate: candidate, startFrame: start, handle: .move, others: [obstacle]
        )
        #expect(resolved.minX == start.minX)   // horizontal blocked
        #expect(resolved.minY == 250)          // vertical slid through
    }

    @Test("A move fully boxed in stays put")
    internal func moveBoxedInStaysPut() {
        // start x:[100,500] y:[100,400]. Two obstacles that don't touch start but
        // block a down-right move on BOTH axes: one to the right (blocks the
        // horizontal-only attempt), one below (blocks the vertical-only attempt).
        let rightWall = CGRect(x: 510, y: 100, width: 140, height: 300)   // clears start (510 > 500)
        let bottomWall = CGRect(x: 100, y: 410, width: 400, height: 140)  // clears start (410 > 400)
        let candidate = CGRect(x: 250, y: 250, width: 400, height: 300)   // moved down-right into both
        let resolved = PanelResizeMath.resolveOverlap(
            candidate: candidate, startFrame: start, handle: .move, others: [rightWall, bottomWall]
        )
        #expect(resolved == start)
    }

    @Test("A resize that would overlap is rejected to the start frame")
    internal func resizeRejectedOnOverlap() {
        let obstacle = CGRect(x: 520, y: 100, width: 200, height: 300)
        // Grow the trailing edge into the obstacle.
        let candidate = CGRect(x: 100, y: 100, width: 600, height: 300)
        let resolved = PanelResizeMath.resolveOverlap(
            candidate: candidate, startFrame: start, handle: .trailing, others: [obstacle]
        )
        #expect(resolved == start)
    }

    @Test("Flush (edge-sharing) panels are not treated as overlapping")
    internal func flushPanelsAllowed() {
        // Obstacle's left edge is exactly the candidate's right edge.
        let obstacle = CGRect(x: 500, y: 100, width: 200, height: 300)
        let candidate = CGRect(x: 100, y: 100, width: 400, height: 300)  // maxX == 500
        let resolved = PanelResizeMath.resolveOverlap(
            candidate: candidate, startFrame: start, handle: .trailing, others: [obstacle]
        )
        #expect(resolved == candidate)
    }

    @Test("An already-overlapping neighbour never blocks the drag")
    internal func alreadyOverlappingIsRecoverable() {
        // start already intersects this obstacle (a stale saved layout). It must
        // not freeze the panel — the user has to be able to drag apart.
        let obstacle = CGRect(x: 120, y: 120, width: 400, height: 300)
        let candidate = PanelResizeMath.apply(
            handle: .move, startFrame: start, translation: CGSize(width: 300, height: 0), bounds: bounds
        )
        let resolved = PanelResizeMath.resolveOverlap(
            candidate: candidate, startFrame: start, handle: .move, others: [obstacle]
        )
        #expect(resolved == candidate)  // moved freely despite starting overlapped
    }

    // MARK: - Vacant slot for newly-added panels

    @Test("Vacant slot returns the top-left when the canvas is empty")
    internal func vacantSlotEmptyCanvas() {
        let slot = PanelResizeMath.vacantSlot(
            size: CGSize(width: 300, height: 200), others: [], bounds: bounds
        )
        #expect(slot.origin == .zero)
    }

    @Test("Vacant slot avoids an occupied top-left corner")
    internal func vacantSlotAvoidsOccupied() {
        let occupied = CGRect(x: 0, y: 0, width: 300, height: 200)
        let slot = PanelResizeMath.vacantSlot(
            size: CGSize(width: 300, height: 200), others: [occupied], bounds: bounds
        )
        #expect(!slot.intersects(occupied))
    }

    @Test("Vacant slot falls back to the top-left when the canvas is full")
    internal func vacantSlotFullCanvasFallback() {
        let wall = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let slot = PanelResizeMath.vacantSlot(
            size: CGSize(width: 300, height: 200), others: [wall], bounds: bounds
        )
        #expect(slot.origin == .zero)
    }

    // MARK: - Settle-on-release (nearestVacant)

    @Test("A drop in clear space stays exactly where it landed")
    internal func nearestVacantClearDropUnchanged() {
        let desired = CGRect(x: 300, y: 250, width: 300, height: 200)
        let other = CGRect(x: 0, y: 0, width: 200, height: 200)
        let settled = PanelResizeMath.nearestVacant(to: desired, others: [other], bounds: bounds)
        #expect(settled == desired)  // no overlap → untouched, no far-corner snap
    }

    @Test("A drop over a neighbour settles onto a nearby non-overlapping spot")
    internal func nearestVacantOverlappingDropSettlesClear() {
        // Drop lands squarely on top of a neighbour; must relocate to a clear spot.
        let neighbour = CGRect(x: 300, y: 200, width: 300, height: 200)
        let desired = CGRect(x: 320, y: 210, width: 300, height: 200)  // overlaps neighbour
        let settled = PanelResizeMath.nearestVacant(to: desired, others: [neighbour], bounds: bounds)
        #expect(!settled.intersects(neighbour))       // no longer overlapping
        #expect(settled.size == desired.size)         // size preserved
    }

    @Test("Settle picks the vacant spot nearest the drop, not a far corner")
    internal func nearestVacantChoosesClosest() {
        // A neighbour occupies the left; a panel dropped just onto its right portion
        // should settle immediately to its right, not jump to the top-left origin.
        let neighbour = CGRect(x: 0, y: 0, width: 400, height: 800)  // full-height left wall
        let desired = CGRect(x: 380, y: 500, width: 300, height: 200)  // straddles the wall's right edge
        let settled = PanelResizeMath.nearestVacant(to: desired, others: [neighbour], bounds: bounds)
        #expect(!settled.intersects(neighbour))
        #expect(settled.minX >= 400)          // settled to the RIGHT of the wall
        #expect(settled.minY > 300)           // stayed near the drop's vertical band, not the top
    }

    @Test("Settle falls back to the origin-size frame when the canvas is full")
    internal func nearestVacantFullCanvasFallback() {
        let wall = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let desired = CGRect(x: 100, y: 100, width: 300, height: 200)
        let settled = PanelResizeMath.nearestVacant(to: desired, others: [wall], bounds: bounds)
        #expect(settled.origin == .zero)
        #expect(settled.size == desired.size)
    }

    // MARK: - Snapping

    @Test("A move within threshold of the left wall snaps flush to it")
    internal func moveSnapsToLeftWall() {
        // minX = 5 is within 8px of the wall at 0.
        let frame = CGRect(x: 5, y: 200, width: 400, height: 300)
        let snapped = PanelResizeMath.snap(frame: frame, handle: .move, others: [], bounds: bounds)
        #expect(snapped.minX == 0)
        #expect(snapped.size == frame.size)  // size preserved on a move-snap
    }

    @Test("A move snaps its trailing edge flush to a neighbour's leading edge")
    internal func moveSnapsToNeighbourEdge() {
        // Neighbour's left edge at x=510; our right edge at 506 is 4px away.
        let neighbour = CGRect(x: 510, y: 200, width: 200, height: 300)
        let frame = CGRect(x: 106, y: 200, width: 400, height: 300)  // maxX = 506
        let snapped = PanelResizeMath.snap(frame: frame, handle: .move, others: [neighbour], bounds: bounds)
        #expect(snapped.maxX == 510)   // now flush against the neighbour
        #expect(snapped.width == 400)  // size unchanged
    }

    @Test("A move beyond the threshold is left untouched")
    internal func moveNoSnapBeyondThreshold() {
        let frame = CGRect(x: 40, y: 200, width: 400, height: 300)  // 40px from wall
        let snapped = PanelResizeMath.snap(frame: frame, handle: .move, others: [], bounds: bounds)
        #expect(snapped == frame)
    }

    @Test("A trailing resize snaps the right edge onto a neighbour")
    internal func trailingResizeSnapsToNeighbour() {
        let neighbour = CGRect(x: 600, y: 100, width: 200, height: 300)
        // Right edge at 596 is 4px shy of the neighbour's left edge at 600.
        let frame = CGRect(x: 100, y: 100, width: 496, height: 300)  // maxX = 596
        let snapped = PanelResizeMath.snap(frame: frame, handle: .trailing, others: [neighbour], bounds: bounds)
        #expect(snapped.maxX == 600)      // dragged edge latched onto the neighbour
        #expect(snapped.minX == 100)      // anchored edge unmoved
    }

    @Test("A resize snap on the trailing edge leaves the leading edge fixed")
    internal func resizeSnapKeepsAnchor() {
        // Snap to the right wall; left edge must not move.
        let frame = CGRect(x: 100, y: 100, width: 896, height: 300)  // maxX = 996, wall at 1000
        let snapped = PanelResizeMath.snap(frame: frame, handle: .trailing, others: [], bounds: bounds)
        #expect(snapped.maxX == bounds.width)
        #expect(snapped.minX == 100)
    }

    // MARK: - Auto-fill resize

    /// Two panels side by side, flush at x=500. Left = `start` (100..500),
    /// right neighbour 500..900.
    private var rightNeighbour: CGRect { CGRect(x: 500, y: 100, width: 400, height: 300) }

    @Test("Shrinking the trailing edge grows the flush neighbour into the gap")
    internal func shrinkGrowsFlushNeighbour() {
        // Drag the left panel's right edge from 500 to 400 (shrink by 100).
        let candidate = CGRect(x: 100, y: 100, width: 300, height: 300)  // maxX = 400
        let result = PanelResizeMath.autoFillResize(
            candidate: candidate, startFrame: start, handle: .trailing,
            others: [rightNeighbour], bounds: bounds
        )
        #expect(result.frame.maxX == 400)                 // panel shrank as dragged
        let grown = try? #require(result.neighbours[0])
        #expect(grown?.minX == 400)                       // neighbour's near edge followed
        #expect(grown?.maxX == 900)                       // far edge pinned — it grew
    }

    @Test("Growing the trailing edge shrinks the flush neighbour, not past its min")
    internal func growShrinksFlushNeighbourToMin() {
        // Drag the right edge far past the neighbour's far edge.
        let candidate = CGRect(x: 100, y: 100, width: 850, height: 300)  // maxX = 950
        let result = PanelResizeMath.autoFillResize(
            candidate: candidate, startFrame: start, handle: .trailing,
            others: [rightNeighbour], bounds: bounds
        )
        // Neighbour can't shrink below min width; its near edge stops there and
        // the panel is capped at that same line — never overlapping.
        let squeezed = try? #require(result.neighbours[0])
        #expect(squeezed?.width == PanelResizeMath.minSize.width)
        #expect(squeezed?.maxX == 900)                    // far edge still pinned
        #expect(result.frame.maxX == 900 - PanelResizeMath.minSize.width)
    }

    @Test("A non-adjacent neighbour on the growth side is a hard wall")
    internal func nonAdjacentNeighbourBlocksGrowth() {
        // Neighbour separated by a gap (starts at 600, panel ends at 500).
        let detached = CGRect(x: 600, y: 100, width: 300, height: 300)
        let candidate = CGRect(x: 100, y: 100, width: 700, height: 300)  // wants maxX = 800
        let result = PanelResizeMath.autoFillResize(
            candidate: candidate, startFrame: start, handle: .trailing,
            others: [detached], bounds: bounds
        )
        #expect(result.frame.maxX == 600)                 // stopped at the detached edge
        #expect(result.neighbours.isEmpty)                // nothing tracked it
    }

    @Test("A neighbour that doesn't share the dragged edge's rows is ignored")
    internal func neighbourOutsideRowSpanIgnored() {
        // Flush in X but far below in Y — doesn't share the right edge's span.
        let below = CGRect(x: 500, y: 600, width: 400, height: 150)
        let candidate = CGRect(x: 100, y: 100, width: 300, height: 300)
        let result = PanelResizeMath.autoFillResize(
            candidate: candidate, startFrame: start, handle: .trailing,
            others: [below], bounds: bounds
        )
        #expect(result.frame.maxX == 400)                 // free to shrink
        #expect(result.neighbours.isEmpty)                // the below panel untouched
    }

    @Test("Shrinking the leading edge grows a flush left neighbour rightward")
    internal func shrinkLeadingGrowsLeftNeighbour() {
        // Left neighbour 0..100 flush against start's left edge at 100.
        let left = CGRect(x: 0, y: 100, width: 100, height: 300)
        // Drag start's left edge from 100 to 200 (shrink from the left).
        let candidate = CGRect(x: 200, y: 100, width: 300, height: 300)
        let result = PanelResizeMath.autoFillResize(
            candidate: candidate, startFrame: start, handle: .leading,
            others: [left], bounds: bounds
        )
        #expect(result.frame.minX == 200)
        let grown = try? #require(result.neighbours[0])
        #expect(grown?.minX == 0)                         // far edge pinned
        #expect(grown?.maxX == 200)                       // near edge followed the gap
    }

    @Test("A corner resize auto-fills flush neighbours on both moved edges")
    internal func cornerResizeFillsBothAxes() {
        let rightN = CGRect(x: 500, y: 100, width: 400, height: 300)
        let belowN = CGRect(x: 100, y: 400, width: 400, height: 300)  // flush at y=400
        // Bottom-trailing corner shrunk: maxX 500→400, maxY 400→320.
        let candidate = CGRect(x: 100, y: 100, width: 300, height: 220)
        let result = PanelResizeMath.autoFillResize(
            candidate: candidate, startFrame: start, handle: .bottomTrailing,
            others: [rightN, belowN], bounds: bounds
        )
        #expect(result.frame.maxX == 400)
        #expect(result.frame.maxY == 320)
        #expect(result.neighbours[0]?.minX == 400)        // right neighbour grew left
        #expect(result.neighbours[1]?.minY == 320)        // below neighbour grew up
    }
}
