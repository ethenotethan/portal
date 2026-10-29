import Foundation

/// A JSON-RPC request the gateway sends to the client (`srq-…` ids): a blocking
/// question an agent thread is waiting on — `clarify`, `approval`, `sudo`,
/// `secret`, or a Desktop-only bridge Portal has no surface for. The client
/// answers with a bare response frame carrying the same id
/// (`JSONRPCServerResponse`); the gateway withdraws an open request through
/// the `request.cancel` event.
internal struct ServerRequest: Equatable, Sendable {
    internal let id: String
    internal let method: String
    internal let sessionID: String?
    internal let params: [String: AnyCodable]

    internal init(id: String, method: String, sessionID: String? = nil, params: [String: AnyCodable] = [:]) {
        self.id = id
        self.method = method
        self.sessionID = sessionID ?? params["session_id"]?.stringValue
        self.params = params
    }

    /// Decode a raw inbound frame. Only a string id with a method other than
    /// the event envelope qualifies: Portal's own calls use integer ids, so a
    /// reply to one of them can never be mistaken for a request.
    internal static func from(json: [String: Any]) -> ServerRequest? {
        guard let id = json["id"] as? String, !id.isEmpty,
              let method = json["method"] as? String, method != "event" else {
            return nil
        }
        let params = (json["params"] as? [String: Any] ?? [:]).mapValues { AnyCodable(any: $0) }
        return ServerRequest(id: id, method: method, params: params)
    }

    /// One `open_requests` entry of a `session.resume` reply: the same request
    /// re-delivered because the question was still unanswered when the socket
    /// dropped.
    internal static func from(openRequest entry: [String: AnyCodable]) -> ServerRequest? {
        guard let id = entry["id"]?.stringValue, !id.isEmpty,
              let method = entry["method"]?.stringValue else {
            return nil
        }
        return ServerRequest(id: id, method: method, params: entry["params"]?.dictionaryValue ?? [:])
    }

    /// The event the app already renders for this request; nil when Portal has
    /// no handler, in which case the caller declines with -32601 so the agent
    /// fails fast instead of waiting out the gateway's timeout.
    internal var event: GatewayEvent? {
        switch method {
        case "clarify":
            return .clarifyRequest(payload: ClarifyPayload.from(serverRequest: self))
        case "approval":
            return .approvalRequest(payload: ApprovalPayload.from(params, requestID: id))
        case "sudo":
            return .sudoRequest
        case "secret":
            return .secretRequest(
                prompt: params["prompt"]?.stringValue ?? "",
                envVar: params["env_var"]?.stringValue ?? ""
            )
        default:
            return nil
        }
    }

    /// Prompts Portal surfaces but cannot collect a value for (it has no masked
    /// input UI). They are answered as skipped — `""` is the contract's
    /// "declined" — so the tool proceeds without the value rather than parking
    /// the agent until the gateway times the prompt out.
    internal var isAnsweredAsSkipped: Bool {
        method == "sudo" || method == "secret"
    }
}

/// Outbound answer to a `ServerRequest`: a bare JSON-RPC response frame with
/// the request's string id, either a `result` object or an `error`.
internal struct JSONRPCServerResponse: Encodable, Equatable {
    internal struct ErrorBody: Encodable, Equatable {
        internal let code: Int
        internal let message: String
    }

    internal let jsonrpc: String = "2.0"
    internal let id: String
    internal let result: [String: AnyCodable]?
    internal let error: ErrorBody?

    internal static func result(id: String, _ result: [String: AnyCodable]) -> JSONRPCServerResponse {
        JSONRPCServerResponse(id: id, result: result, error: nil)
    }

    /// The decline the gateway contract asks for when a client has no handler
    /// for a request method.
    internal static func methodNotFound(id: String, method: String) -> JSONRPCServerResponse {
        JSONRPCServerResponse(
            id: id,
            result: nil,
            error: ErrorBody(code: JSONRPCError.methodNotFound.code, message: "Portal has no handler for \(method)")
        )
    }
}
