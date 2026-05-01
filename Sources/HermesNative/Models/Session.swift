import Foundation

/// A Hermes agent session.
/// Fields match the gateway's `session.list` response schema.
struct Session: Identifiable, Equatable {
    let id: String              // Gateway field: "id" (short hex like "a1b2c3d4")
    var title: String?          // Gateway field: "title" (auto-generated or user-set)
    var preview: String?        // Gateway field: "preview" (last message preview)
    var source: String?         // Gateway field: "source" (telegram, cli, tui, etc.)
    var messageCount: Int       // Gateway field: "message_count"
    var startedAt: Date?        // Gateway field: "started_at" (epoch seconds)

    /// Local-only: session key for resume (not returned by session.list)
    var localKey: String?

    /// Local-only: stored in UserDefaults, overrides gateway title
    var localTitle: String?

    var isRunning: Bool = false // Derived from source context, not from gateway

    /// Whether this session was created by this app (we have the resume key).
    var isOwned: Bool {
        localKey != nil && !localKey!.isEmpty
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}
