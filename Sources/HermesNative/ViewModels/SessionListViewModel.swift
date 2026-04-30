import Foundation
import Combine
import SwiftUI

/// Manages the list of sessions and session creation/resumption/killing.
/// Tracks session titles locally in UserDefaults (gateway doesn't store them).
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?
    @Published var isLoading: Bool = false

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Local Title Storage

    private static let titlesKey = "hermes.sessionTitles"

    /// Client-side titles keyed by session ID. Persisted to UserDefaults.
    private var localTitles: [String: String] {
        get {
            (UserDefaults.standard.dictionary(forKey: Self.titlesKey) as? [String: String]) ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.titlesKey)
        }
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

    /// Store a title for a session (called when first user message is sent).
    func updateSessionTitle(id: String, title: String) {
        var titles = localTitles
        titles[id] = title
        localTitles = titles

        // Update the in-memory session too
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = title
        }
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
            // Merge local titles into fetched sessions
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

        var session = Session(
            id: sessionID,
            key: sessionID, // server generates key internally
            isRunning: false
        )
        // Restore local title if we've seen this session before
        if let title = localTitles[sessionID] {
            session.title = title
        }
        sessions.append(session)
        activeSessionID = sessionID
        return sessionID
    }

    /// Resume an existing session by key and set it as active.
    func resumeSession(_ session: Session) async throws -> String {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }
        let sessionID = try await client.resumeSession(key: session.key)
        activeSessionID = sessionID

        // Update isRunning in local list
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
        // Clean up local title
        var titles = localTitles
        titles.removeValue(forKey: id)
        localTitles = titles

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
