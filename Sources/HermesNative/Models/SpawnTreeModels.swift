import Foundation

// MARK: - Spawn Tree Entry (from spawn_tree.list)

struct SpawnTreeEntry: Identifiable {
    let id = UUID()
    let path: String
    let sessionID: String
    let startedAt: Double?
    let finishedAt: Double
    let label: String
    let subagentCount: Int

    var finishedDate: Date? {
        finishedAt > 0 ? Date(timeIntervalSince1970: finishedAt) : nil
    }

    var startedDate: Date? {
        startedAt.map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Spawn Tree Snapshot (from spawn_tree.load)

struct SpawnTreeSnapshot: Identifiable {
    let id = UUID()
    let sessionID: String
    let startedAt: Double?
    let finishedAt: Double
    let label: String
    let subagents: [SubagentRecord]

    var duration: TimeInterval {
        let start = startedAt ?? finishedAt
        return finishedAt - start
    }

    static func from(_ d: [String: AnyCodable]) -> SpawnTreeSnapshot? {
        let subagents = d["subagents"]?.arrayValue?.compactMap { item -> SubagentRecord? in
            guard let sd = item.dictionaryValue else { return nil }
            return SubagentRecord.from(sd)
        } ?? []

        return SpawnTreeSnapshot(
            sessionID: d["session_id"]?.stringValue ?? "",
            startedAt: d["started_at"]?.doubleValue,
            finishedAt: d["finished_at"]?.doubleValue ?? 0,
            label: d["label"]?.stringValue ?? "",
            subagents: subagents
        )
    }
}

// MARK: - Subagent Record (within a spawn tree snapshot)

struct SubagentRecord: Identifiable {
    let id = UUID()
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let depth: Int
    let status: String
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let apiCalls: Int?
    let costUSD: Double?
    let filesRead: [String]
    let filesWritten: [String]
    let durationSeconds: Double?
    let children: [SubagentRecord]

    var totalTokens: Int? {
        guard let i = inputTokens, let o = outputTokens else { return nil }
        return i + o
    }

    static func from(_ d: [String: AnyCodable]) -> SubagentRecord? {
        guard let goal = d["goal"]?.stringValue, !goal.isEmpty else { return nil }
        let children = d["children"]?.arrayValue?.compactMap { item -> SubagentRecord? in
            guard let cd = item.dictionaryValue else { return nil }
            return SubagentRecord.from(cd)
        } ?? []

        return SubagentRecord(
            goal: goal,
            taskCount: d["task_count"]?.intValue ?? 1,
            taskIndex: d["task_index"]?.intValue ?? 0,
            depth: d["depth"]?.intValue ?? 0,
            status: d["status"]?.stringValue ?? "completed",
            model: d["model"]?.stringValue,
            inputTokens: d["input_tokens"]?.intValue,
            outputTokens: d["output_tokens"]?.intValue,
            apiCalls: d["api_calls"]?.intValue,
            costUSD: d["cost_usd"]?.doubleValue,
            filesRead: d["files_read"]?.arrayValue?.map { $0.stringValue ?? "" } ?? [],
            filesWritten: d["files_written"]?.arrayValue?.map { $0.stringValue ?? "" } ?? [],
            durationSeconds: d["duration_seconds"]?.doubleValue,
            children: children
        )
    }
}

// MARK: - Session Usage (from session.usage)

struct SessionUsage {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let totalTokens: Int
    let apiCalls: Int
    let costUSD: Double?
    let contextUsed: Int?
    let contextMax: Int?
    let contextPercent: Int?
    let compressions: Int?

    static func from(_ d: [String: AnyCodable]) -> SessionUsage? {
        SessionUsage(
            model: d["model"]?.stringValue ?? "",
            inputTokens: d["input"]?.intValue ?? 0,
            outputTokens: d["output"]?.intValue ?? 0,
            cacheReadTokens: d["cache_read"]?.intValue,
            cacheWriteTokens: d["cache_write"]?.intValue,
            totalTokens: d["total"]?.intValue ?? 0,
            apiCalls: d["calls"]?.intValue ?? 0,
            costUSD: d["cost_usd"]?.doubleValue,
            contextUsed: d["context_used"]?.intValue,
            contextMax: d["context_max"]?.intValue,
            contextPercent: d["context_percent"]?.intValue,
            compressions: d["compressions"]?.intValue
        )
    }
}
