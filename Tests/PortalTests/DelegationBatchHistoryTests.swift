import Testing
import Foundation
@testable import Portal

/// Pins the persistence layer for delegation batches: the record snapshot
/// (`DelegationBatchRecord`) faithfully captures a terminal batch, and the store
/// (`DelegationBatchHistoryStore`) dedupes by id, scopes queries per session, and
/// caps growth. Uses the `testing:` seam so no disk I/O and each suite gets an
/// isolated store.
@MainActor
@Suite("Delegation batch history")
private struct DelegationBatchHistoryTests {

    /// A finished batch of `count` subagents under one root.
    private func finishedBatch(count: Int, base: TimeInterval = 0) throws -> DelegationBatch {
        let root = SpawnNode(id: "root", goal: "prompt", status: .completed)
        for i in 0..<count {
            let child = SpawnNode(
                id: "a\(i)", goal: "task \(i)", depth: 1,
                taskCount: count, taskIndex: i, parentID: "root",
                status: .completed, createdAt: Date(timeIntervalSince1970: base + Double(i))
            )
            child.completedAt = Date(timeIntervalSince1970: base + Double(i) + 5)
            child.costUSD = 0.02
            child.inputTokens = 200
            child.outputTokens = 100
            child.apiCalls = 3
            child.toolCalls = [NodeToolCall(name: "Read"), NodeToolCall(name: "Edit")]
            child.filesWritten = ["/tmp/a/\(i).swift"]
            root.children.append(child)
        }
        return try #require(DelegationBatch.batches(in: root).first)
    }

    @Test("record snapshots a batch faithfully")
    private func recordSnapshot() throws {
        let batch = try finishedBatch(count: 2)
        let record = DelegationBatchRecord(batch, sessionID: "s1")
        #expect(record.sessionID == "s1")
        #expect(record.subagents.count == 2)
        #expect(record.status == "completed")
        #expect(record.totalCost == 0.04)
        #expect(record.totalTokens == 600)
        let first = record.subagents[0]
        #expect(first.toolNames == ["Read", "Edit"])
        #expect(first.filesWritten == ["/tmp/a/0.swift"])
        #expect(first.apiCalls == 3)
        #expect(first.duration == 5)
    }

    @Test("record round-trips through Codable")
    private func codableRoundTrip() throws {
        let record = DelegationBatchRecord(try finishedBatch(count: 3), sessionID: "s1")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DelegationBatchRecord.self, from: data)
        #expect(decoded.id == record.id)
        #expect(decoded.subagents.count == 3)
        #expect(decoded.totalTokens == record.totalTokens)
    }

    @Test("store dedupes by batch id")
    private func dedupe() throws {
        let store = DelegationBatchHistoryStore(testing: true)
        let batch = try finishedBatch(count: 2)
        store.record(batch, sessionID: "s1")
        store.record(batch, sessionID: "s1") // same id again
        #expect(store.records(for: "s1").count == 1)
    }

    @Test("store ignores a still-running batch")
    private func ignoresRunning() throws {
        let store = DelegationBatchHistoryStore(testing: true)
        let root = SpawnNode(id: "root", goal: "prompt", status: .running)
        for i in 0..<2 {
            let child = SpawnNode(
                id: "a\(i)", goal: "t", depth: 1, taskCount: 2, taskIndex: i,
                parentID: "root", status: i == 0 ? .completed : .running,
                createdAt: Date(timeIntervalSince1970: Double(i))
            )
            if i == 0 { child.completedAt = Date(timeIntervalSince1970: 5) }
            root.children.append(child)
        }
        let batch = try #require(DelegationBatch.batches(in: root).first)
        store.record(batch, sessionID: "s1")
        #expect(store.records(for: "s1").isEmpty)
    }

    @Test("records are scoped per session")
    private func perSession() throws {
        let store = DelegationBatchHistoryStore(testing: true)
        store.record(try finishedBatch(count: 2, base: 0), sessionID: "s1")
        store.record(try finishedBatch(count: 3, base: 100), sessionID: "s2")
        #expect(store.records(for: "s1").count == 1)
        #expect(store.records(for: "s2").count == 1)
        #expect(store.records(for: "s1").first?.subagents.count == 2)
        #expect(store.records(for: "s2").first?.subagents.count == 3)
        #expect(store.records(for: "unknown").isEmpty)
    }

    @Test("records for a session are sorted oldest first")
    private func sortedByStart() throws {
        let store = DelegationBatchHistoryStore(testing: true)
        store.record(try finishedBatch(count: 2, base: 500), sessionID: "s1")
        store.record(try finishedBatch(count: 2, base: 10), sessionID: "s1")
        let recs = store.records(for: "s1")
        #expect(recs.count == 2)
        #expect(recs[0].startedAt < recs[1].startedAt)
    }
}
