import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "ChatHistoryStore")

/// Persists chat message history per session to local disk.
/// Files live in Application Support/portal/sessions/<id>.json
/// This gives instant history on app restart + offline viewing.
@MainActor
final class ChatHistoryStore {
    static let shared = ChatHistoryStore()

    private let fileManager = FileManager.default
    private let sessionsDir: URL

    private init() {
        sessionsDir = Self.resolveSessionsDir(fileManager: fileManager)
        try? fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    /// Where session transcripts live. Extracted from `init` so the
    /// test-process redirection is assertable without constructing the
    /// singleton, which would itself touch whichever directory it picks.
    ///
    /// Under test this is a scratch directory, NOT Application Support. Tests
    /// drive `ChatViewModel`, which saves history on every message change, and
    /// the store is a singleton with no injection seam — so a plain unit run
    /// wrote fixture transcripts (`stable-a.json`, `session-b.json`,
    /// `background-skills-<UUID>.json`, …) straight into the user's real
    /// `portal/sessions`. That is not merely litter: `localSessionIDs()` is the
    /// "local-only sessions" source for the sidebar, so every fixture file
    /// became a session row the user had to scroll past, and the real sessions
    /// were pushed out of view. Same defect class as the gateway pushes
    /// `ArtifactStore.isTestProcess` already guards — one shared singleton, one
    /// process-external side effect, no seam.
    ///
    /// Per-process-unique so parallel swift-testing suites don't collide, and
    /// under `/tmp` so nothing survives to be mistaken for user data.
    private static func resolveSessionsDir(fileManager: FileManager) -> URL {
        if ProcessInfo.isTestProcess {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "portal-tests-\(ProcessInfo.processInfo.processIdentifier)/sessions",
                    isDirectory: true
                )
        }
        guard let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("ChatHistoryStore: cannot locate Application Support directory")
            return URL(fileURLWithPath: "/tmp/portal/sessions")
        }
        return appSupport.appendingPathComponent("portal/sessions", isDirectory: true)
    }

    /// Test seam: the directory this store reads and writes.
    internal var sessionsDirectoryForTesting: URL { sessionsDir }

    // MARK: - Save

    /// Save messages for a session. Called after every message change.
    func saveMessages(_ messages: [ChatMessage], forSession sessionID: String) {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(messages)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("Failed to save session \(sessionID): \(error)")
            }
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
            log.error("Failed to load session \(sessionID): \(error)")
            return nil
        }
    }

    /// Load messages off-main for large sessions to avoid UI jank.
    func loadMessagesBackground(forSession sessionID: String) async -> [ChatMessage]? {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: file)
                return try JSONDecoder().decode([ChatMessage].self, from: data)
            } catch {
                log.error("Failed to load session \(sessionID): \(error)")
                return nil
            }
        }.value
    }

    // MARK: - Delete

    /// Delete local history for a session.
    func deleteMessages(forSession sessionID: String) {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        Task.detached(priority: .background) { [file] in
            try? FileManager.default.removeItem(at: file)
        }
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

    /// Check if a session has local history on disk without loading it.
    func hasLocalMessages(forSession sessionID: String) -> Bool {
        let file = sessionsDir.appendingPathComponent("\(sessionID).json")
        return fileManager.fileExists(atPath: file.path)
    }

    /// Extract the first user message content from local history for display as fallback title.
    func firstUserMessage(forSession sessionID: String) -> String? {
        guard let messages = loadMessages(forSession: sessionID) else { return nil }
        return messages.first(where: { $0.role == .user })?.content
    }

    /// Off-main variant for batch title population. Reads and decodes in a
    /// detached task so the main thread is never blocked.
    nonisolated internal func firstUserMessageBackground(forSession sessionID: String) async -> String? {
        let dir = sessionsDir
        let file = dir.appendingPathComponent("\(sessionID).json")
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let data = try Data(contentsOf: file)
                let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
                return messages.first(where: { $0.role == .user })?.content
            } catch {
                return nil
            }
        }.value
    }
}
