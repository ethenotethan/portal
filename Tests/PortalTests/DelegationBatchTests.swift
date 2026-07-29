import Testing
import Foundation
@testable import Portal

/// Pins `DelegationBatch.batches(in:)` — the reconstruction of async delegation
/// batches from a flat spawn tree. The batch shape only exists implicitly (a set
/// of sibling subagents sharing a `taskCount` / contiguous `taskIndex` run), so
/// these tests fix the grouping rules: real batches are recovered, lone
/// sequential delegations are not batches, and a second wave under the same
/// parent splits into its own batch.
@Suite("Delegation batch grouping")
private struct DelegationBatchTests {

    /// Build a root with N child subagents forming one batch of `count`.
    private func root(withBatchOf count: Int, taskCount: Int? = nil, base: TimeInterval = 0) -> SpawnNode {
        let root = SpawnNode(id: "root", goal: "prompt", status: .running)
        for i in 0..<count {
            let child = SpawnNode(
                id: "a\(i)",
                goal: "task \(i)",
                depth: 1,
                taskCount: taskCount ?? count,
                taskIndex: i,
                parentID: "root",
                status: .completed,
                createdAt: Date(timeIntervalSince1970: base + Double(i))
            )
            child.completedAt = Date(timeIntervalSince1970: base + Double(i) + 5)
            child.costUSD = 0.01
            child.inputTokens = 100
            child.outputTokens = 50
            root.children.append(child)
        }
        return root
    }

    @Test("recovers a single batch of parallel subagents")
    private func singleBatch() {
        let batches = DelegationBatch.batches(in: root(withBatchOf: 3))
        #expect(batches.count == 1)
        #expect(batches.first?.subagents.count == 3)
        #expect(batches.first?.taskCount == 3)
        #expect(batches.first?.status == .completed)
    }

    @Test("aggregates cost and tokens across members")
    private func aggregates() {
        let batch = DelegationBatch.batches(in: root(withBatchOf: 4)).first
        #expect(batch?.totalCost == 0.04)
        #expect(batch?.totalTokens == 600) // 4 × (100 + 50)
    }

    @Test("duration spans earliest start to latest completion")
    private func duration() {
        // members start at t=0,1,2 and each ends 5s later → last ends at t=7.
        let batch = DelegationBatch.batches(in: root(withBatchOf: 3)).first
        #expect(batch?.startedAt == Date(timeIntervalSince1970: 0))
        #expect(batch?.endedAt == Date(timeIntervalSince1970: 7))
        #expect(batch?.duration(asOf: Date(timeIntervalSince1970: 100)) == 7)
    }

    @Test("a lone sequential delegation is not a batch")
    private func loneDelegationIgnored() {
        let root = SpawnNode(id: "root", goal: "prompt", status: .running)
        let solo = SpawnNode(
            id: "solo", goal: "one task", depth: 1,
            taskCount: 1, taskIndex: 0, parentID: "root", status: .completed
        )
        root.children.append(solo)
        #expect(DelegationBatch.batches(in: root).isEmpty)
    }

    @Test("running member keeps the batch running with nil endedAt")
    private func runningBatch() {
        let root = root(withBatchOf: 3)
        root.children[1].status = .running
        root.children[1].completedAt = nil
        let batch = DelegationBatch.batches(in: root).first
        #expect(batch?.status == .running)
        #expect(batch?.isRunning == true)
        #expect(batch?.endedAt == nil)
        // Duration measured against `now` while running.
        #expect(batch?.duration(asOf: Date(timeIntervalSince1970: 50)) == 50)
    }

    @Test("a failed member makes the batch failed")
    private func failedBatch() {
        let root = root(withBatchOf: 2)
        root.children[0].status = .failed
        #expect(DelegationBatch.batches(in: root).first?.status == .failed)
    }

    @Test("a second wave under the same parent splits into its own batch")
    private func secondWaveSplits() {
        let root = root(withBatchOf: 2, base: 0)
        // A later wave (taskIndex resets to 0) delegated at t=100.
        for i in 0..<2 {
            let child = SpawnNode(
                id: "b\(i)", goal: "wave2 \(i)", depth: 1,
                taskCount: 2, taskIndex: i, parentID: "root", status: .completed,
                createdAt: Date(timeIntervalSince1970: 100 + Double(i))
            )
            child.completedAt = Date(timeIntervalSince1970: 110)
            root.children.append(child)
        }
        let batches = DelegationBatch.batches(in: root)
        #expect(batches.count == 2)
        // Sorted by start: first wave, then second.
        #expect(batches[0].startedAt == Date(timeIntervalSince1970: 0))
        #expect(batches[1].startedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("mid-flight batch: taskCount known before all members stream in")
    private func partialBatch() {
        // Gateway said task_count = 4 but only 2 members have arrived so far.
        let root = root(withBatchOf: 2, taskCount: 4)
        let batch = DelegationBatch.batches(in: root).first
        #expect(batch != nil)
        #expect(batch?.subagents.count == 2)
        #expect(batch?.taskCount == 4)
    }
}
