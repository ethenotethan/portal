import Foundation

/// Persists chat message history per session to local disk.
/// Files live in Application Support/hermes-native/sessions/<id>.json
/// This gives instant history on app restart + offline viewing.
@MainActor
final class ChatHistoryStore {
    static let shared = ChatHistoryStore()

    private let fileManager = FileManager.default
    private let sessionsDir: URL

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDir = appSupport.appendingPathComponent("hermes-native/sessions", isDirectory: true)
        try? fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    // MARK: - Save

    /// Save messages for a session. Called after every message change.
    func saveMessages(_ messages: [ChatMessage], forSession sessionID: String) {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("[ChatHistoryStore] Failed to save session \(sessionID): \(error)")
        }
    }

    // MARK: - Load

    /// Load messages for a session. Returns nil if no local history exists.
    func loadMessages(forSession sessionID: String) -> [ChatMessage]? {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            NSLog("[ChatHistoryStore] Failed to load session \(sessionID): \(error)")
            return nil
        }
    }

    // MARK: - Delete

    /// Delete local history for a session.
    func deleteMessages(forSession sessionID: String) {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        try? fileManager.removeItem(at: file)
    }

    // MARK: - List

    /// List all session IDs with local history.
    func localSessionIDs() -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}
