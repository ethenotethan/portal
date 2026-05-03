import Foundation

/// Point-in-time diagnostics for HermesNative's single WebSocket gateway client.
struct GatewayDebugSnapshot: Equatable {
    struct EventRecord: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let direction: Direction
        let name: String
        let sessionID: String?
        let detail: String

        enum Direction: String, Equatable {
            case inbound
            case outbound
            case dropped
            case state
            case error
        }
    }

    var connectionState: String = "disconnected"
    var socketURL: String = "—"
    var isAuthenticated: Bool = false
    var hasCFAuthCookie: Bool = false
    var activeSessionID: String?
    var lastSessionKey: String?
    var pendingRequestIDs: [Int] = []
    var pendingRequestMethods: [Int: String] = [:]
    var reconnectAttempt: Int = 0
    var lastOpenAt: Date?
    var lastCloseAt: Date?
    var lastError: String?
    var recentEvents: [EventRecord] = []

    var pendingRequestCount: Int { pendingRequestIDs.count }
}
