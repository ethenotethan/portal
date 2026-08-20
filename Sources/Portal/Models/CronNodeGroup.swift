import CoreGraphics
import SwiftUI

// MARK: - CronNodeGroup

/// A cluster of non-cron nodes that share a ref scheme (`wiki`, `telegram`, …).
///
/// Destinations and sources filed under the same scheme read as one "place":
/// every `wiki:*` ref — events, chains, entities, queries — belongs to the wiki
/// group, so the graph can draw a soft boundary around them and, when collapsed,
/// stand the whole cluster in with a single super-node ("cron writes to wiki").
/// Cron nodes are the actors that run and are never grouped.
internal struct CronNodeGroup: Identifiable, Hashable {
    /// The ref scheme (`node.type`) — also the group's display label.
    internal let key: String
    /// Member node ids, in graph order.
    internal let memberIDs: [String]
    /// The node kind the super-node adopts for color/glyph. `artifact` wins when
    /// a scheme mixes produced artifacts with plain sources, since a written
    /// store is the more meaningful summary of the cluster.
    internal let kind: String

    internal var id: String { key }
    /// The synthetic id of this group's collapsed super-node. The `group:` prefix
    /// never collides with real node ids (crons are bare hex, refs are
    /// `scheme:value`) and lets a tap recognize a super-node to expand it.
    internal var superNodeID: String { "group:\(key)" }
}

// MARK: - CronNodeGrouping

internal enum CronNodeGrouping {
    /// Partition a graph's resource/artifact/sink nodes by ref scheme, keeping
    /// only schemes with ≥2 members — a lone ref isn't worth a boundary. Sorted
    /// by descending member count then key so the draw and legend order is
    /// stable across reloads.
    internal static func groups(from graph: CronGraph) -> [CronNodeGroup] {
        var membersByKey: [String: [CronGraphNode]] = [:]
        for node in graph.nodes where node.kind != "cron" {
            membersByKey[node.type, default: []].append(node)
        }
        return membersByKey.compactMap { key, nodes -> CronNodeGroup? in
            guard nodes.count >= 2 else { return nil }
            let kind = nodes.contains { $0.kind == "artifact" } ? "artifact" : (nodes.first?.kind ?? "source")
            return CronNodeGroup(key: key, memberIDs: nodes.map(\.id), kind: kind)
        }
        .sorted { $0.memberIDs.count != $1.memberIDs.count ? $0.memberIDs.count > $1.memberIDs.count : $0.key < $1.key }
    }
}

// MARK: - CronGroupHull

/// The soft boundary drawn around a group's member nodes — the "circle that goes
/// around the inner circles". Pure geometry so it can be unit-tested without a
/// canvas.
internal enum CronGroupHull {
    /// The convex hull of `points` (Andrew's monotone chain), returned
    /// counter-clockwise. Fewer than three points can't bound an area, so they're
    /// returned unchanged for the caller to handle (a 2-node group draws a
    /// capsule around the pair instead).
    internal static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    /// A smooth closed boundary around `points`, inflated by `padding` away from
    /// the centroid so it clears the node bodies, with corners rounded by routing
    /// the path through edge midpoints via quad curves. Degrades gracefully: an
    /// empty set yields an empty path, and one or two points yield a padded
    /// circle / capsule so a small group still reads as one region.
    internal static func path(around points: [CGPoint], padding: CGFloat) -> Path {
        guard !points.isEmpty else { return Path() }
        let cx = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let cy = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        let center = CGPoint(x: cx, y: cy)

        if points.count < 3 {
            if points.count == 1 {
                let r = padding
                return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            return capsule(from: points[0], to: points[1], padding: padding)
        }

        // Push each hull vertex outward from the centroid so the boundary clears
        // the glyphs, then round it by threading quad curves through the
        // midpoints of consecutive inflated vertices.
        let inflated = convexHull(points).map { vertex -> CGPoint in
            let dx = vertex.x - center.x, dy = vertex.y - center.y
            let len = max(hypot(dx, dy), 0.001)
            return CGPoint(x: vertex.x + dx / len * padding, y: vertex.y + dy / len * padding)
        }
        guard inflated.count >= 3 else { return Path() }
        var path = Path()
        let start = midpoint(inflated[inflated.count - 1], inflated[0])
        path.move(to: start)
        for i in inflated.indices {
            let next = midpoint(inflated[i], inflated[(i + 1) % inflated.count])
            path.addQuadCurve(to: next, control: inflated[i])
        }
        path.closeSubpath()
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// A rounded capsule enclosing two points — the boundary for a two-member
    /// group, where a convex hull would collapse to a line.
    private static func capsule(from a: CGPoint, to b: CGPoint, padding: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let nx = -dy / len * padding, ny = dx / len * padding
        var path = Path()
        path.move(to: CGPoint(x: a.x + nx, y: a.y + ny))
        path.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
        path.addArc(center: b, radius: padding,
                    startAngle: .radians(atan2(ny, nx)), endAngle: .radians(atan2(-ny, -nx)), clockwise: false)
        path.addLine(to: CGPoint(x: a.x - nx, y: a.y - ny))
        path.addArc(center: a, radius: padding,
                    startAngle: .radians(atan2(-ny, -nx)), endAngle: .radians(atan2(ny, nx)), clockwise: false)
        path.closeSubpath()
        return path
    }
}
