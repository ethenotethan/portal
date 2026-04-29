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
