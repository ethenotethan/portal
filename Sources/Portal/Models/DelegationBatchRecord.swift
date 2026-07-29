import Foundation

/// A persisted snapshot of one subagent in a finished delegation batch. Flattened
/// and `Codable` — enough to render a past batch's lane and detail without the
/// live `SpawnNode` (which is in-memory and gone once the session closes).
internal struct DelegationSubagentRecord: Codable, Identifiable {
    internal let id: String
    internal let goal: String
    internal let taskIndex: Int
    internal let model: String?
    /// `NodeStatus.rawValue` — stored as a string so persistence never depends on
    /// the enum's layout (mirrors `CronRunRecord.status`).
    internal let status: String
    internal let startedAt: Date
    internal let completedAt: Date?
    internal let costUSD: Double?
    internal let totalTokens: Int?
    internal let apiCalls: Int?
    internal let toolNames: [String]
    internal let filesRead: [String]
    internal let filesWritten: [String]

    /// Wall-clock runtime, or 0 if it never recorded a completion.
    internal var duration: TimeInterval {
        guard let completedAt else { return 0 }
        return completedAt.timeIntervalSince(startedAt)
    }
}

/// A persisted snapshot of a finished delegation batch — the durable counterpart
/// to the live `DelegationBatch`. Mirrors `CronRunRecord`: `Codable`, id-keyed,
/// stored per session so you can reopen a past session and still see the batches
/// it ran. Only *terminal* batches are recorded (see `DelegationBatchHistoryStore`).
internal struct DelegationBatchRecord: Codable, Identifiable {
    internal let id: String
    /// The session that ran this batch — the history store keys records by it.
    internal let sessionID: String
    internal let parentGoal: String?
    internal let startedAt: Date
    internal let endedAt: Date?
    internal let status: String
    internal let taskCount: Int
    internal let totalCost: Double
    internal let totalTokens: Int
    internal let subagents: [DelegationSubagentRecord]

    internal var duration: TimeInterval {
        guard let endedAt else { return 0 }
        return endedAt.timeIntervalSince(startedAt)
    }

    internal var durationLabel: String {
        let d = duration
        if d < 60 { return String(format: "%.1fs", d) }
        if d < 3600 { return String(format: "%.1fm", d / 60) }
        return String(format: "%.1fh", d / 3600)
    }
}

extension DelegationBatchRecord {
    /// Snapshot a live batch for persistence. Call only on a terminal batch —
    /// `endedAt` is expected to be set.
    internal init(_ batch: DelegationBatch, sessionID: String) {
        self.init(
            id: batch.id,
            sessionID: sessionID,
            parentGoal: batch.parentGoal,
            startedAt: batch.startedAt,
            endedAt: batch.endedAt,
            status: batch.status.rawValue,
            taskCount: batch.taskCount,
            totalCost: batch.totalCost,
            totalTokens: batch.totalTokens,
            subagents: batch.subagents.map { node in
                DelegationSubagentRecord(
                    id: node.id,
                    goal: node.goal,
                    taskIndex: node.taskIndex,
                    model: node.model,
                    status: node.status.rawValue,
                    startedAt: node.createdAt,
                    completedAt: node.completedAt,
                    costUSD: node.costUSD,
                    totalTokens: node.totalTokens,
                    apiCalls: node.apiCalls,
                    toolNames: node.toolCalls.map(\.name),
                    filesRead: node.filesRead,
                    filesWritten: node.filesWritten
                )
            }
        )
    }
}
