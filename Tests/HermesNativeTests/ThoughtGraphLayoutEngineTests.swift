import Testing
import Foundation
@testable import HermesNative

/// Geometry of the time-plot layout: x tracks start time, width tracks
/// duration (floored), lanes stack by actor, running bars grow to `now`.
@MainActor
@Suite("Thought graph timeline layout")
internal struct ThoughtGraphLayoutEngineTests {

    private typealias Engine = ThoughtGraphLayoutEngine

    private func node(
        _ id: String, start: TimeInterval, duration: Double?,
        agentID: String? = nil, ownerAgentID: String? = nil,
        name: String = "read_file", complete: Bool = true
    ) -> ThoughtGraphNode {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        return ThoughtGraphNode(
            id: id, name: name,
            isComplete: complete,
            durationSeconds: duration,
            startedAt: t0.addingTimeInterval(start),
            completedAt: duration.map { t0.addingTimeInterval(start + $0) },
            agentID: agentID, ownerAgentID: ownerAgentID
        )
    }

    private func layout(_ engine: Engine, _ id: String) -> ThoughtGraphLayout? {
        engine.layouts.first { $0.nodeID == id }
    }

    @Test("x is proportional to time since the earliest start")
    internal func xTracksTime() throws {
        let engine = Engine()
        engine.layout(nodes: [
            node("a", start: 0, duration: 1),
            node("b", start: 10, duration: 1),
        ])
        let a = try #require(layout(engine, "a"))
        let b = try #require(layout(engine, "b"))
        // b starts 10s after a → 10 * pixelsPerSecond further right.
        #expect(abs((b.x - a.x) - 10 * Engine.pixelsPerSecond) < 0.001)
    }

    @Test("width is proportional to duration")
    internal func widthTracksDuration() throws {
        let engine = Engine()
        engine.layout(nodes: [node("a", start: 0, duration: 3)])
        let a = try #require(layout(engine, "a"))
        #expect(abs(a.width - 3 * Engine.pixelsPerSecond) < 0.001)
    }

    @Test("sub-threshold durations are floored to minBarWidth, not zero")
    internal func minWidthFloor() throws {
        let engine = Engine()
        engine.layout(nodes: [node("fast", start: 0, duration: 0.001)])
        let bar = try #require(layout(engine, "fast"))
        #expect(bar.width == Engine.minBarWidth)
    }

    @Test("subagent tool calls stack into a lane below the main loop")
    internal func laneStacking() throws {
        let engine = Engine()
        engine.layout(nodes: [
            node("m1", start: 0, duration: 1),
            node("sub", start: 1, duration: 5, agentID: "s1", name: "agent"),
            node("s1t1", start: 2, duration: 1, ownerAgentID: "s1"),
        ])
        let main = try #require(layout(engine, "m1"))
        let subTool = try #require(layout(engine, "s1t1"))
        // Main lane is y=0; the subagent lane sits one laneHeight below.
        #expect(main.y == 0)
        #expect(subTool.y == Engine.laneHeight)
        #expect(engine.lanes.count == 2)
    }

    @Test("a running bar (no completedAt) grows with now")
    internal func runningBarGrows() throws {
        let engine = Engine()
        let running = node("live", start: 0, duration: nil, complete: false)
        engine.layout(nodes: [running])
        let base = try #require(layout(engine, "live"))
        // 8 seconds after its start, the live width reflects 8s of elapsed time.
        let started = try #require(running.startedAt)
        let now = started.addingTimeInterval(8)
        let w = engine.liveWidth(for: running, laidOut: base.width, now: now)
        #expect(abs(w - 8 * Engine.pixelsPerSecond) < 0.001)
    }

    @Test("a spawned agent gets a spawn edge from its delegating parent")
    internal func spawnEdge() {
        let engine = Engine()
        var agent = node("agent-s1", start: 2, duration: 4, agentID: "s1", name: "agent")
        agent.parentIDs = ["deleg"]
        engine.layout(nodes: [
            node("deleg", start: 1, duration: 1, name: "delegate_task"),
            agent,
        ])
        #expect(engine.edges.contains { $0.from == "deleg" && $0.to == "agent-s1" && $0.kind == .spawn })
    }

    @Test("empty input clears all published state")
    internal func emptyClears() {
        let engine = Engine()
        engine.layout(nodes: [node("a", start: 0, duration: 1)])
        #expect(!engine.layouts.isEmpty)
        engine.layout(nodes: [])
        #expect(engine.layouts.isEmpty)
        #expect(engine.lanes.isEmpty)
        #expect(engine.timeOrigin == nil)
    }
}
