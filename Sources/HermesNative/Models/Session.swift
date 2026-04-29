import Foundation

/// A Hermes agent session.
struct Session: Identifiable, Equatable {
    let id: String          // Short ID used in JSON-RPC (e.g. "a1b2c3d4")
    let key: String         // Full session key (for session.resume)
    var title: String?
    var model: String?
    var source: String?
    var createdAt: Date?
    var isRunning: Bool

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}
