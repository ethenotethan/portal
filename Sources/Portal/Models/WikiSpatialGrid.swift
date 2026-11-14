import Foundation
import CoreGraphics

/// Uniform spatial hash over a set of 2D points, rebuilt in O(n) per use.
///
/// The wiki graph's two hot spatial questions — "which nodes are near this
/// node?" (repulsion) and "which node is under the cursor?" (hit-testing) —
/// were both answered by scanning every node. On a 5,000-page wiki that is
/// 12.8M pair visits per physics iteration and a 5k walk per mouse move. A
/// grid whose cell is the repulsion cutoff answers both from the 3×3 block of
/// cells around a point: every neighbour within the cutoff is guaranteed to
/// sit in that block, so nothing is missed and almost nothing is over-scanned.
///
/// Built with a counting sort into two flat arrays (`cellStart` prefix
/// offsets, `items` node indices) — no per-cell allocations, so a rebuild on
/// every iteration costs less than one row of the old pairwise loop. The grid
/// is a value: the physics step builds one per iteration off the main thread
/// and the simulation store caches one for hit-testing until positions move.
internal struct WikiSpatialGrid: Sendable {
    /// Side of a cell in world units. At least the requested size; grown when
    /// the point cloud is so spread out that `maxCellsPerAxis` would otherwise
    /// be exceeded (a runaway node must not allocate a million cells).
    internal let cellSize: CGFloat
    /// World position of cell (0, 0)'s top-left corner.
    internal let origin: CGPoint
    internal let columns: Int
    internal let rows: Int
    /// Prefix offsets into `items`: cell `c` holds `items[cellStart[c] ..< cellStart[c + 1]]`.
    internal let cellStart: [Int]
    /// Point indices grouped by cell.
    internal let items: [Int]

    /// Cap on cells per axis; the cell grows past the requested size beyond it.
    internal static let defaultMaxCellsPerAxis = 256

    internal init(points: [CGPoint], cellSize requestedCell: CGFloat, maxCellsPerAxis: Int = WikiSpatialGrid.defaultMaxCellsPerAxis) {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for point in points where point.x.isFinite && point.y.isFinite {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        if minX > maxX { minX = 0; maxX = 0; minY = 0; maxY = 0 }
        let axisCap = max(1, maxCellsPerAxis)
        let extentX = maxX - minX, extentY = maxY - minY
        var cell = max(requestedCell, 1)
        cell = max(cell, extentX / CGFloat(axisCap), extentY / CGFloat(axisCap))
        cellSize = cell
        origin = CGPoint(x: minX, y: minY)
        columns = min(axisCap, Int(extentX / cell) + 1)
        rows = min(axisCap, Int(extentY / cell) + 1)

        let cellCount = columns * rows
        var counts = [Int](repeating: 0, count: cellCount + 1)
        var cellOfPoint = [Int](repeating: 0, count: points.count)
        for (index, point) in points.enumerated() {
            let coordinate = Self.coordinate(of: point, origin: origin, cellSize: cell, columns: columns, rows: rows)
            let cellIndex = coordinate.row * columns + coordinate.column
            cellOfPoint[index] = cellIndex
            counts[cellIndex + 1] += 1
        }
        for cellIndex in 0..<cellCount { counts[cellIndex + 1] += counts[cellIndex] }
        var cursor = counts
        var sorted = [Int](repeating: 0, count: points.count)
        for index in points.indices {
            let cellIndex = cellOfPoint[index]
            sorted[cursor[cellIndex]] = index
            cursor[cellIndex] += 1
        }
        cellStart = counts
        items = sorted
    }

    internal var cellCount: Int { columns * rows }
    internal var count: Int { items.count }

    private static func coordinate(of point: CGPoint, origin: CGPoint, cellSize: CGFloat, columns: Int, rows: Int) -> (column: Int, row: Int) {
        guard point.x.isFinite, point.y.isFinite else { return (0, 0) }
        let column = Int(((point.x - origin.x) / cellSize).rounded(.down))
        let row = Int(((point.y - origin.y) / cellSize).rounded(.down))
        return (min(max(column, 0), columns - 1), min(max(row, 0), rows - 1))
    }

    /// The cell a point falls in, clamped to the grid (points outside the
    /// original bounds land in the nearest edge cell).
    internal func coordinate(of point: CGPoint) -> (column: Int, row: Int) {
        Self.coordinate(of: point, origin: origin, cellSize: cellSize, columns: columns, rows: rows)
    }

    internal func cellIndex(column: Int, row: Int) -> Int { row * columns + column }

    /// Point indices stored in one cell.
    internal func indices(inCell cellIndex: Int) -> ArraySlice<Int> {
        items[cellStart[cellIndex]..<cellStart[cellIndex + 1]]
    }

    /// Visit every point in the 3×3 block of cells around `point`. Any point
    /// within `cellSize` of `point` is in this block; the caller still checks
    /// the actual distance.
    @inline(__always)
    internal func forEachIndex(around point: CGPoint, _ body: (Int) -> Void) {
        let center = coordinate(of: point)
        let rowRange = max(0, center.row - 1)...min(rows - 1, center.row + 1)
        let columnRange = max(0, center.column - 1)...min(columns - 1, center.column + 1)
        for row in rowRange {
            for column in columnRange {
                let cellIndex = row * columns + column
                for slot in cellStart[cellIndex]..<cellStart[cellIndex + 1] {
                    body(items[slot])
                }
            }
        }
    }

    /// Point indices in the 3×3 block of cells around `point`.
    internal func indices(around point: CGPoint) -> [Int] {
        var out: [Int] = []
        forEachIndex(around: point) { out.append($0) }
        return out
    }

    /// Point indices in every cell that intersects `rect` — a superset of the
    /// points inside it, cheap enough to cull the label pass to the viewport.
    internal func indices(intersecting rect: CGRect) -> [Int] {
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return [] }
        let low = coordinate(of: CGPoint(x: rect.minX, y: rect.minY))
        let high = coordinate(of: CGPoint(x: rect.maxX, y: rect.maxY))
        var out: [Int] = []
        for row in low.row...high.row {
            for column in low.column...high.column {
                out.append(contentsOf: indices(inCell: row * columns + column))
            }
        }
        return out
    }
}
