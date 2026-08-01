import Foundation

/// The approvals a session is blocked on, oldest first.
///
/// **Why this is a queue and not one slot:** the gateway keeps a per-session
/// FIFO list of blocked agent threads (`tools/approval.py`, `_gateway_queues`),
/// and parallel subagents or concurrent `execute_code` handlers can each block
/// at the same time. Portal used to hold a single `ApprovalPayload?` and simply
/// assign to it, so a second request silently overwrote the first: the prompt
/// vanished from the UI while an agent thread stayed blocked on it until the
/// approval timeout expired and resolved it as a denial the user never chose.
///
/// **Why the order is not the user's to pick:** `approval.respond` carries no
/// per-request identifier. The gateway's `resolve_gateway_approval` pops the
/// *oldest* entry, or with `all: true` resolves every one. So this type only
/// ever exposes head-or-all: answering out of order is not representable on the
/// wire, and offering it in the UI would apply the answer to the wrong command.
internal struct ApprovalQueue: Equatable {
    /// Oldest first — index 0 is the one the gateway will resolve next.
    internal private(set) var entries: [ApprovalPayload] = []

    internal init(entries: [ApprovalPayload] = []) {
        self.entries = entries
    }

    /// The approval the user is being asked about right now.
    internal var head: ApprovalPayload? { entries.first }

    internal var isEmpty: Bool { entries.isEmpty }

    /// Total blocked agent threads, including the one on screen.
    internal var count: Int { entries.count }

    /// How many are stacked up behind the visible one — what the badge counts.
    internal var waitingBehind: Int { max(0, entries.count - 1) }

    /// The queued approvals the user cannot answer yet, in the order they will
    /// be asked. Shown read-only so a second `rm -rf` is at least *visible*
    /// while it waits.
    internal var upcoming: [ApprovalPayload] { Array(entries.dropFirst()) }

    /// Append a newly-arrived request.
    ///
    /// Deliberately **no deduplication**. An agent can legitimately run the same
    /// command twice, so two identical payloads are usually two real blocked
    /// threads; collapsing them by content would answer one and leave the other
    /// hanging until it timed out. A duplicate delivery is the lesser harm: the
    /// user answers twice, and the second resolve is a no-op the gateway reports
    /// as `resolved: 0`.
    internal mutating func enqueue(_ payload: ApprovalPayload) {
        entries.append(payload)
    }

    /// Drop the head — the entry the gateway resolves for a normal response.
    /// Returns what was removed, or nil when nothing was pending.
    @discardableResult
    internal mutating func removeHead() -> ApprovalPayload? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    /// Drop everything, matching a response sent with `all: true`.
    internal mutating func removeAll() {
        entries.removeAll()
    }
}
