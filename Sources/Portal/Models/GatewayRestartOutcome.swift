import Foundation

/// What happened to a `gateway.restart` request — as distinct from whether the
/// gateway actually came back, which only reconnecting can tell us.
///
/// The split matters because a successful restart and a dead socket look
/// identical from the caller's side. The gateway sends its response and then
/// re-execs ~0.15s later; if that frame doesn't drain in time (loaded host,
/// coalesced write, exec winning the race) the call fails with a timeout or a
/// disconnect even though the restart is underway. So a lost socket is treated
/// as `accepted` — "the request probably landed, go verify by reconnecting" —
/// and the reconnect is what decides success. Treating it as a failure instead
/// would report "restart failed" for the most common successful path.
internal enum GatewayRestartRequestOutcome: Equatable {
    /// The gateway acknowledged, or the transport died in the way a restart
    /// makes it die. Either way: wait for the gateway to come back.
    case accepted
    /// The gateway predates the restart RPC (`gateway.restart` is unknown).
    /// Nothing was restarted and nothing will be — the control should be
    /// hidden rather than shown failing.
    case unsupported
    /// The gateway answered, and the answer was an error.
    case failed(String)

    /// Classify a JSON-RPC reply to `gateway.restart`.
    internal static func from(response: JSONRPCResponse) -> GatewayRestartRequestOutcome {
        guard let error = response.error else { return .accepted }
        if error.code == JSONRPCError.methodNotFound.code { return .unsupported }
        return .failed(error.message)
    }

    /// Classify a thrown error from the same call.
    ///
    /// `timedOut`, `disconnected` and `notConnected` are all shapes of "the
    /// socket went away", which is the expected outcome of a restart that
    /// worked. Anything else is a real failure.
    internal static func from(error: Error) -> GatewayRestartRequestOutcome {
        switch error {
        case GatewayError.timedOut, GatewayError.disconnected, GatewayError.notConnected:
            return .accepted
        case GatewayError.rpcError(let rpc):
            return rpc.code == JSONRPCError.methodNotFound.code ? .unsupported : .failed(rpc.message)
        default:
            return .failed(error.localizedDescription)
        }
    }
}

/// The user-visible stages of a restart, in order. Drives one label and one
/// spinner rather than letting the raw connection state leak through — mid
/// restart the transport legitimately reads "Reconnecting (attempt 3)…", which
/// looks like a fault when it is the restart working as designed.
internal enum GatewayRestartPhase: Equatable {
    case idle
    /// Sending `gateway.restart` and waiting for the acknowledgement.
    case requesting
    /// The gateway is re-execing. Nothing to do but dial it until it answers.
    case waitingForGateway
    case succeeded
    case failed(String)
    /// The connected gateway has no restart RPC — a `git pull` + manual
    /// bounce is still the only way on that host.
    case unsupported

    internal var isBusy: Bool {
        switch self {
        case .requesting, .waitingForGateway: return true
        case .idle, .succeeded, .failed, .unsupported: return false
        }
    }

    /// Status line shown under the button. `nil` while idle — a restart that
    /// hasn't been asked for needs no commentary.
    internal var statusText: String? {
        switch self {
        case .idle: return nil
        case .requesting: return "Asking the gateway to restart…"
        case .waitingForGateway: return "Gateway is restarting — waiting for it to come back…"
        case .succeeded: return "Gateway restarted and reconnected."
        case .failed(let reason): return "Restart failed: \(reason)"
        case .unsupported: return "This gateway is too old to restart itself. Bounce it on the host."
        }
    }
}
