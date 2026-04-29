import Foundation

/// Inbound JSON-RPC 2.0 response (for method call replies).
struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?

    var isSuccess: Bool { error == nil }
}

/// JSON-RPC error object.
struct JSONRPCError: Decodable, Equatable {
    let code: Int
    let message: String

    static let parseError = JSONRPCError(code: -32700, message: "parse error")
    static let invalidRequest = JSONRPCError(code: -32600, message: "invalid request")
    static let methodNotFound = JSONRPCError(code: -32601, message: "method not found")
    static let invalidParams = JSONRPCError(code: -32602, message: "invalid params")
    static let internalError = JSONRPCError(code: -32603, message: "internal error")

    // Hermes-specific error codes
    static let sessionNotFound = JSONRPCError(code: 4001, message: "session not found")
    static let sessionBusy = JSONRPCError(code: 4009, message: "session busy")
}

/// Inbound JSON-RPC event (server-initiated, no request id).
struct JSONRPCEventMessage: Decodable {
    let jsonrpc: String
    let method: String // always "event"
    let params: EventParams

    struct EventParams: Decodable {
        let type: String
        let sessionID: String?
        let payload: AnyCodable?

        enum CodingKeys: String, CodingKey {
            case type
            case sessionID = "session_id"
            case payload
        }
    }
}
