import Foundation

/// Local-only grouping for Hermes sessions.
/// Stored in UserDefaults by `SessionListViewModel`; never sent to the gateway.
struct SessionFolder: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
