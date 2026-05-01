import Foundation

/// Activity status for a session, derived from `lastActive` and `endedAt`.
enum SessionStatus: Equatable {
    /// Agent was active within the last 60 seconds.
    case active
    /// Session is live (no `endedAt`) but agent has been idle > 60s.
    case idle
    /// Session has ended (`endedAt` is set).
    case ended
}

/// A Hermes agent session.
/// Fields match the gateway's `session.list` response schema.
struct Session: Identifiable, Equatable {
    /// Primary ID — the database-format session key from `session.list`
    /// (e.g., "20260501_112429_d91274").
    /// For newly created sessions, this starts as the short hex ID and gets
    /// updated to the database-format ID after `session.title` resolves.
    var id: String
    var title: String?          // Gateway field: "title" (auto-generated or user-set)
    var preview: String?        // Gateway field: "preview" (last message preview)
    var source: String?         // Gateway field: "source" (telegram, cli, tui, etc.)
    var messageCount: Int       // Gateway field: "message_count"
    var startedAt: Date?        // Gateway field: "started_at" (epoch seconds)
    var endedAt: Date?          // Gateway field: "ended_at" (epoch seconds)
    var lastActive: Date?       // Gateway field: "last_active" (epoch seconds)

    /// The short hex ID used by the gateway's in-memory `_sessions` dict.
    /// Only set for sessions this app created (we got it from `session.create`).
    /// Used as the `session_id` param for RPCs like `session.history`,
    /// `session.usage`, `prompt.submit`, etc.
    var gatewayID: String?

    /// Local-only: stored in UserDefaults, overrides gateway title
    var localTitle: String?

    var isRunning: Bool = false // Derived from source context, not from gateway

    /// Local-only: archived sessions are hidden from "My Sessions" by default.
    var isArchived: Bool = false

    /// Whether this session was created by this app (we have the gateway short hex ID).
    var isOwned: Bool {
        gatewayID != nil && !gatewayID!.isEmpty
    }

    /// The ID to use for gateway RPCs (short hex if we own the session,
    /// database ID as fallback — will fail for _sess-based RPCs on other sessions).
    var rpcID: String {
        gatewayID ?? id
    }

    /// Computed activity status based on `lastActive` and `endedAt`.
    var status: SessionStatus {
        if endedAt != nil { return .ended }
        if let last = lastActive {
            return Date().timeIntervalSince(last) <= 60 ? .active : .idle
        }
        // No lastActive info — treat as idle if still running, ended otherwise
        return isRunning ? .idle : .ended
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}
