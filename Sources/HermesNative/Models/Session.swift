import Foundation

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

    /// The short hex ID used by the gateway's in-memory `_sessions` dict.
    /// Only set for sessions this app created (we got it from `session.create`).
    /// Used as the `session_id` param for RPCs like `session.history`,
    /// `session.usage`, `prompt.submit`, etc.
    var gatewayID: String?

    /// Local-only: stored in UserDefaults, overrides gateway title
    var localTitle: String?

    var isRunning: Bool = false // Derived from source context, not from gateway

    /// Whether this session was created by this app (we have the gateway short hex ID).
    var isOwned: Bool {
        gatewayID != nil && !gatewayID!.isEmpty
    }

    /// The ID to use for gateway RPCs (short hex if we own the session,
    /// database ID as fallback — will fail for _sess-based RPCs on other sessions).
    var rpcID: String {
        gatewayID ?? id
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}
