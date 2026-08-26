import Foundation

/// Inbound JSON-RPC 2.0 response (for method call replies).
struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?
}

/// JSON-RPC error object.
struct JSONRPCError: Decodable, Equatable {
    let code: Int
    let message: String
    /// Optional structured payload (e.g. `wiki.update`'s 409 carries the
    /// server's latest page under `data.latest`). Untyped on purpose.
    internal let data: AnyCodable?

    internal init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static let methodNotFound = JSONRPCError(code: -32601, message: "method not found")

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
