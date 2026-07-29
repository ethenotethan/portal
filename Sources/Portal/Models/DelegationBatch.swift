import Foundation

/// A group of subagents that were delegated *together* — the client-side
/// reconstruction of an async delegation batch (the thing the gateway announces
/// with a `[ASYNC DELEGATION BATCH COMPLETE]` marker). No single gateway event
/// or struct says "batch X started at T1 with agents a,b,c and finished at T2";
/// that shape only exists dispersed across the per-subagent `subagent.*` events
/// that `SpawnTreeStore` already folds into `SpawnNode`s. This type recovers it:
/// sibling subagents sharing a `taskCount` and a contiguous `taskIndex` run are
/// one batch.
///
/// Purely derived and value-typed, so it is cheap to recompute on every store
/// change and trivial to unit-test from constructed `SpawnNode`s.
internal struct DelegationBatch: Identifiable {
    /// Stable within a render pass: the parent id plus the batch's start instant,
    /// so two batches under the same parent (a second wave delegated later) get
    /// distinct ids.
    internal let id: String
    /// The node that delegated this batch (a root prompt or a higher subagent).
    internal let parentID: String
    /// The delegating node's goal, for the batch header ("delegated by …").
    internal let parentGoal: String?
    /// The batch members, ordered by `taskIndex` (agent 0, 1, 2 …).
    internal let subagents: [SpawnNode]
    /// The batch width the gateway reported (`task_count`). Usually equals
    /// `subagents.count`, but can exceed it mid-flight before every member's
    /// spawn event has arrived.
    internal let taskCount: Int
    /// Earliest member creation — the batch's start of the time axis.
    internal let startedAt: Date
    /// Latest member completion, or `nil` while any member is still running.
    internal let endedAt: Date?
    /// Aggregate status: running if any member is; else failed/interrupted if any
    /// ended that way; else completed.
    internal let status: NodeStatus
    /// Sum of member costs (members that reported one).
    internal let totalCost: Double
    /// Sum of member input+output tokens (members that reported them).
    internal let totalTokens: Int

    internal var isRunning: Bool { status.isRunning }

    /// Wall-clock span of the batch as of `now`: start → end for a finished
    /// batch, start → now while it is still running.
    internal func duration(asOf now: Date) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }
}

extension DelegationBatch {
    /// Reconstruct every delegation batch in a spawn tree.
    ///
    /// Groups descendants by their parent, orders each parent's children by
    /// creation (then `taskIndex`), and chunks a run into a new batch whenever
    /// the `taskIndex` fails to advance — i.e. resets to 0 for a fresh wave. Only
    /// genuine batches survive: a group is kept when it has more than one member
    /// or the gateway reported `taskCount > 1` (a batch that has only streamed
    /// its first member so far). Lone sequential delegations (`taskCount == 1`,
    /// one member) are not batches and are dropped.
    internal static func batches(in root: SpawnNode) -> [DelegationBatch] {
        var byParent: [String: [SpawnNode]] = [:]
        for node in root.allDescendants {
            byParent[node.parentID ?? root.id, default: []].append(node)
        }

        var result: [DelegationBatch] = []
        for (parentID, children) in byParent {
            let ordered = children.sorted { lhs, rhs in
                lhs.createdAt != rhs.createdAt
                    ? lhs.createdAt < rhs.createdAt
                    : lhs.taskIndex < rhs.taskIndex
            }

            var current: [SpawnNode] = []
            var lastIndex = Int.min
            for node in ordered {
                // A taskIndex that doesn't advance means a new wave began.
                if node.taskIndex <= lastIndex, !current.isEmpty {
                    result.append(make(parentID: parentID, nodes: current, root: root))
                    current = []
                }
                current.append(node)
                lastIndex = node.taskIndex
            }
            if !current.isEmpty {
                result.append(make(parentID: parentID, nodes: current, root: root))
            }
        }

        return result
            .filter { $0.subagents.count > 1 || $0.taskCount > 1 }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private static func make(parentID: String, nodes: [SpawnNode], root: SpawnNode) -> DelegationBatch {
        let ordered = nodes.sorted { $0.taskIndex < $1.taskIndex }
        let startedAt = ordered.map(\.createdAt).min() ?? Date(timeIntervalSince1970: 0)

        let anyRunning = ordered.contains { $0.status.isRunning }
        let endedAt: Date? = anyRunning
            ? nil
            : ordered.compactMap(\.completedAt).max()

        let status: NodeStatus
        if anyRunning {
            status = .running
        } else if ordered.contains(where: { $0.status == .failed }) {
            status = .failed
        } else if ordered.contains(where: { $0.status == .interrupted }) {
            status = .interrupted
        } else {
            status = .completed
        }

        let parent = root.id == parentID ? root : root.allDescendants.first { $0.id == parentID }

        return DelegationBatch(
            id: "\(parentID)#\(startedAt.timeIntervalSince1970)",
            parentID: parentID,
            parentGoal: parent?.goal,
            subagents: ordered,
            taskCount: max(ordered.map(\.taskCount).max() ?? ordered.count, ordered.count),
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            totalCost: ordered.compactMap(\.costUSD).reduce(0, +),
            totalTokens: ordered.compactMap(\.totalTokens).reduce(0, +)
        )
    }
}
