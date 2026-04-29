import Foundation
import Combine

/// Manages the list of sessions and session creation/resumption.
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    /// Refresh the session list from the gateway.
    @MainActor
    func refreshSessions() async {
        guard let client = gatewayClient else { return }
        do {
            sessions = try await client.listSessions()
        } catch {
            // Silently fail — session list is non-critical
        }
    }

    /// Create a new session and set it as active.
    @MainActor
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

    /// Close a session by ID.
    @MainActor
    func closeSession(id: String) async throws {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }
        try await client.closeSession(sessionID: id)
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
    }

    /// Set the active session.
    func selectSession(id: String) {
        activeSessionID = id
    }
}
