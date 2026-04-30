import Foundation
import Combine
import SwiftUI

/// Manages the list of sessions and session creation/resumption/killing.
/// Tracks session titles and keys locally (gateway list doesn't include keys).
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?
    @Published var isLoading: Bool = false

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Local Storage

    private static let titlesKey = "hermes.sessionTitles"
    private static let keysStoreKey = "hermes.sessionKeys"

    /// Client-side titles keyed by session ID. Persisted to UserDefaults.
    /// Overrides gateway title when present (user has chatted in-app).
    private var localTitles: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.titlesKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.titlesKey) }
    }

    /// Client-side session keys (from session.create responses). Persisted.
    /// session.list doesn't return keys, so we must save them ourselves.
    private var localKeys: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.keysStoreKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.keysStoreKey) }
    }

    /// Get the display title for a session.
    /// Priority: local title (from first user message) > gateway title > preview (truncated) > source > short ID.
    func titleForSession(_ session: Session) -> String {
        // 1. Local title from first user message (highest priority)
        if let local = localTitles[session.id], !local.isEmpty {
            return local
        }
        // 2. Gateway-provided title
        if let title = session.title, !title.isEmpty {
            return title
        }
        // 3. Preview (truncated to 50 chars)
        if let preview = session.preview, !preview.isEmpty {
            return String(preview.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 4. Source-based fallback
        if let source = session.source, !source.isEmpty {
            return "\(source) session"
        }
        // 5. Short ID
        return "Session \(session.id.prefix(8))"
    }

    /// Get the subtitle for a session (second line info).
    func subtitleForSession(_ session: Session) -> String? {
        var parts: [String] = []
        if let source = session.source, !source.isEmpty {
            parts.append(source)
        }
        if session.messageCount > 0 {
            parts.append("\(session.messageCount) msgs")
        }
        if let date = session.startedAt {
            parts.append(date.relativeString)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Get the stored key for a session, if we have one.
    func keyForSession(id: String) -> String? {
        localKeys[id]
    }

    /// Store a title for a session (called when first user message is sent).
    func updateSessionTitle(id: String, title: String) {
        var titles = localTitles
        titles[id] = title
        localTitles = titles

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].localTitle = title
        }
    }

    /// Store a session key (from session.create response).
    func storeSessionKey(id: String, key: String) {
        var keys = localKeys
        keys[id] = key
        localKeys = keys
    }

    // MARK: - Gateway

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    /// Refresh the session list from the gateway, merging local data.
    func refreshSessions() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            var fetched = try await client.listSessions()
            let titles = localTitles
            let keys = localKeys
            for i in fetched.indices {
                // Merge local title (overrides gateway title)
                if let local = titles[fetched[i].id], !local.isEmpty {
                    fetched[i].localTitle = local
                }
                // Merge local key
                if let key = keys[fetched[i].id] {
                    fetched[i].localKey = key
                }
            }
            sessions = fetched
        } catch {
            // Silently fail — session list is non-critical
        }
        isLoading = false
    }

    /// Create a new session and set it as active.
    func createSession() async throws -> String {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }

        let sessionID = try await client.createSession()

        // Save the key locally (gateway returns it only on create)
        if let key = client.lastSessionKey {
            storeSessionKey(id: sessionID, key: key)
        }

        var session = Session(
            id: sessionID,
            messageCount: 0
        )
        session.localKey = localKeys[sessionID]
        if let title = localTitles[sessionID] {
            session.localTitle = title
        }
        sessions.append(session)
        activeSessionID = sessionID
        return sessionID
    }

    /// Resume an existing session by key and set it as active.
    /// Returns nil if we don't have a stored key for this session.
    @discardableResult
    func resumeSession(_ session: Session) async throws -> String? {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }
        guard let key = localKeys[session.id], !key.isEmpty else {
            // No key stored — can't resume. Caller should create a new session instead.
            return nil
        }
        let sessionID = try await client.resumeSession(key: key)
        activeSessionID = sessionID

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].isRunning = true
        }
        return sessionID
    }

    /// Close (kill) a session by ID.
    func closeSession(id: String) async throws {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }
        try await client.closeSession(sessionID: id)
        // Clean up local data
        var titles = localTitles
        titles.removeValue(forKey: id)
        localTitles = titles
        var keys = localKeys
        keys.removeValue(forKey: id)
        localKeys = keys

        withAnimation {
            sessions.removeAll { $0.id == id }
        }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
    }

    /// Set the active session (local selection only).
    func selectSession(id: String) {
        withAnimation {
            activeSessionID = id
        }
    }
}

// MARK: - Date Extension

extension Date {
    /// Human-readable relative time string (e.g. "2h ago", "Just now").
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
