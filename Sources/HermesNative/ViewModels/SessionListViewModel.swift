import Foundation
import Combine
import SwiftUI

/// Manages the list of sessions and session creation/resumption/killing.
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?
    @Published var isLoading: Bool = false

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    /// Refresh the session list from the gateway.
    func refreshSessions() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            sessions = try await client.listSessions()
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

        let session = Session(
            id: sessionID,
            key: sessionID, // server generates key internally
            isRunning: false
        )
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
