import CoreGraphics
import Foundation
import Testing
@testable import Portal

@Suite("Cron node grouping — scheme clusters & hull geometry")
internal struct CronNodeGroupingTests {

    private func node(_ id: String, kind: String, type: String) -> CronGraphNode {
        CronGraphNode(
            id: id, kind: kind, type: type, label: id,
            schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil
        )
    }

    // MARK: - CronNodeGrouping.groups

    @Test("nodes cluster by ref scheme; singletons and crons never form a group")
    internal func groupsByScheme() {
        let graph = CronGraph(
            nodes: [
                node("abc123", kind: "cron", type: "cron"),
                node("wiki:events/a", kind: "artifact", type: "wiki"),
                node("wiki:chains/b", kind: "artifact", type: "wiki"),
                node("wiki:entities/c", kind: "source", type: "wiki"),
                node("telegram:x", kind: "sink", type: "telegram"),
                node("https://only.one", kind: "source", type: "https"),
            ],
            edges: []
        )
        let groups = CronNodeGrouping.groups(from: graph)
        // wiki has 3 members; telegram (1) and https (1) are singletons; cron never groups.
        #expect(groups.count == 1)
        #expect(groups.first?.key == "wiki")
        #expect(groups.first?.memberIDs.count == 3)
        // A scheme mixing artifacts and sources summarizes as an artifact.
        #expect(groups.first?.kind == "artifact")
    }

    @Test("groups sort by descending member count, then key")
    internal func groupsSortStably() {
        let graph = CronGraph(
            nodes: [
                node("wiki:a", kind: "artifact", type: "wiki"),
                node("wiki:b", kind: "artifact", type: "wiki"),
                node("pr:a", kind: "sink", type: "pr"),
                node("pr:b", kind: "sink", type: "pr"),
                node("pr:c", kind: "sink", type: "pr"),
            ],
            edges: []
        )
        let groups = CronNodeGrouping.groups(from: graph)
        #expect(groups.map(\.key) == ["pr", "wiki"])
    }

    @Test("superNodeID namespaces the scheme so it can't collide with a real id")
    internal func superNodeIDIsNamespaced() {
        let group = CronNodeGroup(key: "wiki", memberIDs: ["wiki:a", "wiki:b"], kind: "artifact")
        #expect(group.superNodeID == "group:wiki")
    }

    // MARK: - CronGroupHull

    @Test("convex hull keeps the outer ring and drops interior points")
    internal func convexHullDropsInterior() {
        let square = [
            CGPoint.zero, CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
            CGPoint(x: 5, y: 5), // interior — must not survive
        ]
        let hull = CronGroupHull.convexHull(square)
        #expect(hull.count == 4)
        #expect(!hull.contains(CGPoint(x: 5, y: 5)))
    }

    @Test("fewer than three points pass through unchanged")
    internal func convexHullPassthrough() {
        let pair = [CGPoint.zero, CGPoint(x: 4, y: 4)]
        #expect(CronGroupHull.convexHull(pair) == pair)
    }

    @Test("hull path is empty for no points and non-empty once there's a region")
    internal func hullPathEmptiness() {
        #expect(CronGroupHull.path(around: [], padding: 10).isEmpty)
        let tri = [CGPoint.zero, CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)]
        #expect(!CronGroupHull.path(around: tri, padding: 10).isEmpty)
    }

    @Test("one- and two-node groups draw padded circle and capsule regions")
    internal func smallGroupHullPaths() {
        let single = CronGroupHull.path(around: [CGPoint(x: 20, y: 30)], padding: 10)
        #expect(!single.isEmpty)
        #expect(single.boundingRect == CGRect(x: 10, y: 20, width: 20, height: 20))

        let pair = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 20)]
        let capsule = CronGroupHull.path(around: pair, padding: 5)
        #expect(!capsule.isEmpty)
        #expect(capsule.boundingRect == CGRect(x: 10, y: 15, width: 20, height: 10))
    }
}
