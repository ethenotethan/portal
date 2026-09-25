import Foundation
import Testing
@testable import Portal

/// Pins the gateway's persisted spawn-tree and usage wire contracts. These
/// models feed historical agent supervision after the live `SpawnNode` graph is
/// gone, so snake-case field drift or a malformed child must not erase the rest
/// of a valid snapshot.
@Suite("Spawn tree wire models")
internal struct SpawnTreeModelsTests {
    @Test("snapshot decodes nested agents and drops malformed children")
    internal func snapshotDecodesNestedAgents() throws {
        let validChild: AnyCodable = .dictionary([
            "goal": AnyCodable("Inspect retry behavior"),
            "task_count": AnyCodable(2),
            "task_index": AnyCodable(1),
            "depth": AnyCodable(1),
            "status": AnyCodable("completed"),
            "model": AnyCodable("hermes-4"),
            "input_tokens": AnyCodable(120),
            "output_tokens": AnyCodable(30),
            "api_calls": AnyCodable(3),
            "cost_usd": AnyCodable(0.04),
            "files_read": .array([AnyCodable("Sources/Retry.swift")]),
            "files_written": .array([AnyCodable("Tests/RetryTests.swift")]),
            "duration_seconds": AnyCodable(4.5),
            "children": .array([
                .dictionary([
                    "goal": AnyCodable("Run focused tests"),
                    "input_tokens": AnyCodable(10),
                    "output_tokens": AnyCodable(5),
                ]),
            ]),
        ])
        let malformedChild: AnyCodable = .dictionary(["status": AnyCodable("failed")])
        let nonDictionaryChild = AnyCodable("not an agent")

        let snapshot = try #require(SpawnTreeSnapshot.from([
            "session_id": AnyCodable("session-42"),
            "started_at": AnyCodable(1_000.0),
            "finished_at": AnyCodable(1_012.5),
            "label": AnyCodable("retry audit"),
            "subagents": .array([validChild, malformedChild, nonDictionaryChild]),
        ]))

        #expect(snapshot.sessionID == "session-42")
        #expect(snapshot.label == "retry audit")
        #expect(snapshot.duration == 12.5)
        #expect(snapshot.subagents.count == 1)

        let agent = try #require(snapshot.subagents.first)
        #expect(agent.goal == "Inspect retry behavior")
        #expect(agent.taskCount == 2)
        #expect(agent.taskIndex == 1)
        #expect(agent.status == "completed")
        #expect(agent.model == "hermes-4")
        #expect(agent.totalTokens == 150)
        #expect(agent.apiCalls == 3)
        #expect(agent.costUSD == 0.04)
        #expect(agent.filesRead == ["Sources/Retry.swift"])
        #expect(agent.filesWritten == ["Tests/RetryTests.swift"])
        #expect(agent.durationSeconds == 4.5)
        #expect(agent.children.map(\.goal) == ["Run focused tests"])
        #expect(agent.children.first?.taskCount == 1)
        #expect(agent.children.first?.status == "completed")
    }

    @Test("missing snapshot fields use stable empty defaults")
    internal func snapshotDefaults() throws {
        let snapshot = try #require(SpawnTreeSnapshot.from([:]))

        #expect(snapshot.sessionID.isEmpty)
        #expect(snapshot.label.isEmpty)
        #expect(snapshot.startedAt == nil)
        #expect(snapshot.finishedAt == 0)
        #expect(snapshot.duration == 0)
        #expect(snapshot.subagents.isEmpty)
    }

    @Test("subagent token totals require both halves")
    internal func tokenTotalRequiresInputAndOutput() throws {
        let inputOnly = try #require(SubagentRecord.from([
            "goal": AnyCodable("Inspect logs"),
            "input_tokens": AnyCodable(9),
        ]))

        #expect(inputOnly.totalTokens == nil)
        #expect(SubagentRecord.from(["goal": AnyCodable("")]) == nil)
        #expect(SubagentRecord.from([:]) == nil)
    }

    @Test("session usage maps gateway counters and safe defaults")
    internal func sessionUsageDecodes() {
        let usage = SessionUsage.from([
            "model": AnyCodable("qwen3-coder"),
            "input": AnyCodable(200),
            "output": AnyCodable(80),
            "cache_read": AnyCodable(50),
            "cache_write": AnyCodable(10),
            "total": AnyCodable(340),
            "calls": AnyCodable(4),
            "cost_usd": AnyCodable(0.12),
            "context_used": AnyCodable(1_024),
            "context_max": AnyCodable(32_768),
            "context_percent": AnyCodable(3),
            "compressions": AnyCodable(1),
        ])

        #expect(usage?.model == "qwen3-coder")
        #expect(usage?.inputTokens == 200)
        #expect(usage?.outputTokens == 80)
        #expect(usage?.cacheReadTokens == 50)
        #expect(usage?.cacheWriteTokens == 10)
        #expect(usage?.totalTokens == 340)
        #expect(usage?.apiCalls == 4)
        #expect(usage?.costUSD == 0.12)
        #expect(usage?.contextUsed == 1_024)
        #expect(usage?.contextMax == 32_768)
        #expect(usage?.contextPercent == 3)
        #expect(usage?.compressions == 1)

        let defaults = SessionUsage.from([:])
        #expect(defaults?.model.isEmpty == true)
        #expect(defaults?.inputTokens == 0)
        #expect(defaults?.outputTokens == 0)
        #expect(defaults?.totalTokens == 0)
        #expect(defaults?.apiCalls == 0)
        #expect(defaults?.costUSD == nil)
    }

    @Test("spawn list dates distinguish unfinished entries")
    internal func spawnEntryDates() {
        let finished = SpawnTreeEntry(
            path: "spawn/session-42.json",
            sessionID: "session-42",
            startedAt: 100,
            finishedAt: 112,
            label: "audit",
            subagentCount: 2
        )
        let unfinished = SpawnTreeEntry(
            path: "spawn/session-43.json",
            sessionID: "session-43",
            startedAt: nil,
            finishedAt: 0,
            label: "running",
            subagentCount: 1
        )

        #expect(finished.startedDate == Date(timeIntervalSince1970: 100))
        #expect(finished.finishedDate == Date(timeIntervalSince1970: 112))
        #expect(unfinished.startedDate == nil)
        #expect(unfinished.finishedDate == nil)
    }
}
