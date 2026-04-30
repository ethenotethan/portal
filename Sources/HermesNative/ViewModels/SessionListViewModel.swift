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

    /// Get the display title for a session: local title > model > short ID.
    func titleForSession(_ session: Session) -> String {
        if let local = localTitles[session.id] {
            return local
        }
        if let model = session.model, !model.isEmpty {
            return model
        }
        return "Session \(session.id.prefix(8))"
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
            sessions[idx].title = title
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

    /// Refresh the session list from the gateway, merging local titles.
    func refreshSessions() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            var fetched = try await client.listSessions()
            let titles = localTitles
            for i in fetched.indices {
                if let title = titles[fetched[i].id] {
                    fetched[i].title = title
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
            key: localKeys[sessionID] ?? sessionID,
            isRunning: false
        )
        if let title = localTitles[sessionID] {
            session.title = title
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
