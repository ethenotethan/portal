import Foundation

enum Constants {
    static let defaultGatewayURL = "ws://127.0.0.1:8642/v1/ws"
    static let productionGatewayURL = ProcessInfo.processInfo.environment["HERMES_GATEWAY_URL"] ?? "wss://GATEWAY_HOST/v1/ws"
    static let defaultGatewayPort = 8642
    static let wsPath = "/v1/ws"
    static let maxMessageLength = 1_000_000
    static let reconnectDelay: TimeInterval = 2.0
    static let maxReconnectDelay: TimeInterval = 30.0
}
