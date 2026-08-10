import Foundation

/// Restarting the gateway from the app.
///
/// The gateway ships a `gateway.restart` RPC that re-execs the process in
/// place, so picking up new backend code no longer requires shell access to
/// the host. This is the client half: ask, then wait for it to come back.
extension GatewayClient {

    /// How long to wait for the acknowledgement frame. Deliberately short — the
    /// gateway answers before it re-execs, and if the answer is lost we treat it
    /// as accepted anyway (see `GatewayRestartRequestOutcome`), so a long wait
    /// buys nothing but a longer stare at a spinner.
    internal static let restartAckTimeout: Double = 6

    /// How long to keep dialing a restarting gateway before giving up. A re-exec
    /// re-imports the whole agent stack; on a cold or loaded host that is tens
    /// of seconds, well past the 10-attempt auto-reconnect budget's patience at
    /// its early short delays.
    internal static let restartReturnTimeout: Double = 90

    /// Interval between dial attempts while waiting for the gateway to return.
    /// Each attempt tears down and re-dials, so this is also the floor on how
    /// long a single failed dial is given.
    private static let restartDialInterval: Double = 3

    /// Ask the gateway to restart itself.
    ///
    /// Does NOT wait for it to come back — see `waitForGatewayReturn`. Uses
    /// `call` rather than `callWithRetry` on purpose: retry-on-timeout would
    /// re-send `gateway.restart` to a process that already accepted it and is
    /// mid-exec, restarting the *new* process as its first act.
    internal func requestGatewayRestart() async -> GatewayRestartRequestOutcome {
        onLog?("Requesting gateway restart…", true)
        recordDebugEvent(.state, name: "gateway.restart", detail: "requested")
        do {
            let response = try await call("gateway.restart", timeout: Self.restartAckTimeout)
            let outcome = GatewayRestartRequestOutcome.from(response: response)
            recordDebugEvent(.state, name: "gateway.restart", detail: "ack: \(outcome)")
            return outcome
        } catch {
            let outcome = GatewayRestartRequestOutcome.from(error: error)
            recordDebugEvent(.state, name: "gateway.restart", detail: "no ack: \(outcome)")
            return outcome
        }
    }

    /// Dial the gateway until it answers or `timeout` elapses. Returns whether
    /// it came back.
    ///
    /// Drives the dialing explicitly instead of leaning on auto-reconnect
    /// because the two want different things here. Auto-reconnect backs off
    /// toward 30s and then parks in a terminal `.error` at the attempt cap,
    /// which for a restart would strand the app pointing at a gateway that is
    /// already up. A restart has a known-good endpoint and a known-short
    /// outage, so it wants a steady retry with a deadline.
    internal func waitForGatewayReturn(timeout: Double = GatewayClient.restartReturnTimeout) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .connected = connectionState { return true }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            await forceReconnectAndWait(timeout: min(Self.restartDialInterval, remaining))
        }
        if case .connected = connectionState { return true }
        return false
    }
}
