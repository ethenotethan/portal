import Foundation
import CoreGraphics

/// The 2D force integration behind the wiki graph: charge repulsion between
/// nodes, springs along links, a gentle pull of the centroid toward the
/// canvas centre, friction, and a velocity clamp. Pure and `nonisolated`, so
/// the live tick, the off-main pre-settle and the tests all run the same code.
///
/// ## Why a grid, and how the cutoff was chosen
/// Repulsion used to visit every pair (`for i … for j in i+1…`): 12.8M pair
/// visits per iteration on the 5,055-page wiki, ~25M per frame with two
/// iterations, so frames took longer than the 30 Hz budget and the layout
/// kept drifting for minutes after every drag. Now each node only sees the
/// nodes in the 3×3 block of `WikiSpatialGrid` cells around it, with the cell
/// equal to `repulsionCutoff`, and pairs beyond the cutoff contribute nothing.
///
/// The cutoff is 180 world units — 1.5× the spring length. At that distance a
/// pair's repulsion is `8000 / 180² ≈ 0.25`, already below the spring force a
/// link exerts at the same separation (`60 × 0.008 = 0.48`), so what is
/// dropped is the long tail that mostly cancels in the bulk of a cluster. The
/// visible effect is that hub-and-spoke discs settle ~20–25 % more compact
/// than under the unbounded sum (estimated on the 5k wiki's 1,000-leaf hubs);
/// spring length, charge, friction and the velocity clamp are unchanged, so
/// the layout keeps its character while pair visits fall from 12.8M to a few
/// hundred thousand per iteration.
///
/// Dense cells (the random seed puts every node in a small ring) are
/// stride-sampled beyond `maxCellScan` visits with the force scaled by the
/// stride, bounding the worst case at `9 × maxCellScan` visits per node.
internal enum WikiPhysics2D {

    internal struct Params: Sendable {
        internal var friction: CGFloat = 0.92
        internal var springLength: CGFloat = 120
        internal var springConstant: CGFloat = 0.008
        internal var chargeConstant: CGFloat = 8000
        internal var centerPull: CGFloat = 0.0005
        internal var maxVelocity: CGFloat = 30
        internal var maxRepulsionForce: CGFloat = 500
        /// Repulsion cutoff radius and the grid cell size (see the type doc).
        internal var repulsionCutoff: CGFloat = 180
        /// Nodes visited per grid cell before stride-sampling kicks in.
        internal var maxCellScan: Int = 16

        internal static let standard = Params()
    }

    /// Per-node kinematic state as flat buffers — no strings ride along on
    /// the hot path, so copying a frame to a background task is two array
    /// retains, not 5,000 struct copies.
    internal struct Frame: Sendable, Equatable {
        internal var positions: [CGPoint]
        internal var velocities: [CGVector]

        internal init(positions: [CGPoint], velocities: [CGVector]? = nil) {
            self.positions = positions
            self.velocities = velocities ?? Array(repeating: .zero, count: positions.count)
        }

        /// Σ ½|v|² over the nodes — the settle tests watch it fall.
        internal var kineticEnergy: CGFloat {
            velocities.reduce(0) { $0 + ($1.dx * $1.dx + $1.dy * $1.dy) / 2 }
        }
    }

    /// Which nodes a step moves.
    internal struct Scope: Sendable {
        /// Nodes that integrate this step; nil = all of them. Every other node
        /// is pinned in place but still repels and anchors springs — this is
        /// how a drag on a frozen large graph re-simulates only the dragged
        /// node's neighbourhood.
        internal var active: [Int]?
        /// The node the user is holding: frozen at its live position.
        internal var pinned: Int?
        /// Pull the centroid toward the canvas centre. Off for local steps —
        /// centring a neighbourhood against the whole graph's mean would
        /// drag it sideways.
        internal var centering: Bool

        internal static let all = Scope(active: nil, pinned: nil, centering: true)

        internal static func local(_ active: [Int], pinned: Int?) -> Scope {
            Scope(active: active, pinned: pinned, centering: false)
        }
    }

    /// One frame of force integration over `iterations` sub-steps. Ticks
    /// `wiki.physics.pairs` with the repulsion candidates visited (once per
    /// call, never inside the loop).
    internal static func step(
        _ input: Frame,
        links: [(sourceIndex: Int, targetIndex: Int)],
        alpha: CGFloat,
        canvasSize: CGSize,
        iterations: Int,
        params: Params = .standard,
        scope: Scope = .all
    ) -> Frame {
        var frame = input
        let n = frame.positions.count
        guard n > 0 else { return frame }
        let active: [Int] = scope.active.map { $0.filter { $0 >= 0 && $0 < n } } ?? Array(0..<n)
        let cutoffSq = params.repulsionCutoff * params.repulsionCutoff
        var pairs = 0

        for _ in 0..<max(iterations, 0) {
            var forces = Array(repeating: CGVector.zero, count: n)
            let grid = WikiSpatialGrid(points: frame.positions, cellSize: params.repulsionCutoff)

            // ── Repulsion: each active node against the 3×3 cells around it ──
            for i in active where i != scope.pinned {
                let pi = frame.positions[i]
                var fx: CGFloat = 0, fy: CGFloat = 0
                let center = grid.coordinate(of: pi)
                for row in max(0, center.row - 1)...min(grid.rows - 1, center.row + 1) {
                    for column in max(0, center.column - 1)...min(grid.columns - 1, center.column + 1) {
                        let cellIndex = row * grid.columns + column
                        let start = grid.cellStart[cellIndex], end = grid.cellStart[cellIndex + 1]
                        let count = end - start
                        guard count > 0 else { continue }
                        let stride = count > params.maxCellScan ? (count + params.maxCellScan - 1) / params.maxCellScan : 1
                        let weight = CGFloat(stride)
                        var slot = start
                        while slot < end {
                            let j = grid.items[slot]
                            slot += stride
                            guard j != i else { continue }
                            pairs += 1
                            let dx = pi.x - frame.positions[j].x
                            let dy = pi.y - frame.positions[j].y
                            let distSq = dx * dx + dy * dy
                            guard distSq > 0.01, distSq < cutoffSq else { continue }
                            let force = min(params.chargeConstant / distSq, params.maxRepulsionForce) * weight
                            let dist = distSq.squareRoot()
                            fx += dx / dist * force
                            fy += dy / dist * force
                        }
                    }
                }
                forces[i].dx += fx
                forces[i].dy += fy
            }

            // ── Springs along links (unchanged) ──
            for (si, ti) in links where si >= 0 && si < n && ti >= 0 && ti < n {
                let dx = frame.positions[ti].x - frame.positions[si].x
                let dy = frame.positions[ti].y - frame.positions[si].y
                let dist = (dx * dx + dy * dy).squareRoot()
                guard dist > 0 else { continue }
                let force = (dist - params.springLength) * params.springConstant
                let fx = dx / dist * force, fy = dy / dist * force
                forces[si].dx += fx; forces[si].dy += fy
                forces[ti].dx -= fx; forces[ti].dy -= fy
            }

            // ── Centring: pull the centroid toward the canvas centre ──
            if scope.centering {
                var meanX: CGFloat = 0, meanY: CGFloat = 0
                for p in frame.positions { meanX += p.x; meanY += p.y }
                meanX /= CGFloat(n); meanY /= CGFloat(n)
                let pullX = (canvasSize.width / 2 - meanX) * params.centerPull
                let pullY = (canvasSize.height / 2 - meanY) * params.centerPull
                for i in active where i != scope.pinned {
                    forces[i].dx += pullX
                    forces[i].dy += pullY
                }
            }

            // ── Integrate the active nodes ──
            for i in active where i != scope.pinned {
                var v = frame.velocities[i]
                v.dx = (v.dx + forces[i].dx * alpha) * params.friction
                v.dy = (v.dy + forces[i].dy * alpha) * params.friction
                let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
                if speed > params.maxVelocity {
                    let scale = params.maxVelocity / speed
                    v.dx *= scale; v.dy *= scale
                }
                frame.velocities[i] = v
                frame.positions[i].x += v.dx
                frame.positions[i].y += v.dy
            }
        }
        PerfCounter.add("wiki.physics.pairs", pairs)
        return frame
    }

    /// Alpha schedule shared by the live tick and the pre-settle: decay toward
    /// `floor` by `rate` per landed frame.
    internal static func decayed(_ alpha: CGFloat, toward floor: CGFloat, rate: CGFloat) -> CGFloat {
        alpha + (floor - alpha) * rate
    }
}
