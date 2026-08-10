import Testing
import Foundation
@testable import Portal

/// Regression tests for #178: after reconnect exhaustion the client parked in
/// a terminal `.error` state, and nothing short of an app restart could bring
/// the gateway connection back.
@Suite("Gateway Reconnect Budget")
@MainActor
struct GatewayReconnectBudgetTests {

    private func makeClient() -> GatewayClient {
        // Port 9 (discard) — never dialed in these tests; every test tears the
        // client down via disconnect() before any backoff timer can fire.
        GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
    }

    @Test("exhausted retry cap is terminal until the budget is reset")
    func exhaustedCapIsTerminalUntilReset() {
        let client = makeClient()
        client.setReconnectAttemptForTesting(GatewayClient.maxReconnectAttempts)

        client.handleDisconnectForTesting(reason: "socket died")
        guard case .error = client.connectionState else {
            Issue.record("expected .error at the retry cap, got \(client.connectionState)")
            return
        }

        // An EXPLICIT user connect grants a fresh budget…
        client.resetReconnectBudget(force: true)
        #expect(client.snapshotForDebug.reconnectAttempt == 0)

        // …so the next disconnect schedules attempt 1 instead of staying dead.
        client.handleDisconnectForTesting(reason: "socket died again")
        guard case .reconnecting(let attempt) = client.connectionState else {
            Issue.record("expected .reconnecting after budget reset, got \(client.connectionState)")
            return
        }
        #expect(attempt == 1)

        client.disconnect()
    }

    @Test("duplicate failure signals for one dead socket burn a single attempt")
    func duplicateDisconnectSignalsAreDeduped() {
        let client = makeClient()

        // One dead socket emits several failure signals (receiveLoop error,
        // delegate close, ping failure) — only the first may schedule.
        client.handleDisconnectForTesting(reason: "receiveLoop error")
        client.handleDisconnectForTesting(reason: "delegate close")
        client.handleDisconnectForTesting(reason: "ping failed")

        #expect(client.snapshotForDebug.reconnectAttempt == 1)
        guard case .reconnecting(let attempt) = client.connectionState else {
            Issue.record("expected .reconnecting, got \(client.connectionState)")
            return
        }
        #expect(attempt == 1)

        client.disconnect()
    }

    @Test("resetting an already-zero budget is a no-op")
    func resetIsIdempotent() {
        let client = makeClient()
        client.resetReconnectBudget()
        #expect(client.snapshotForDebug.reconnectAttempt == 0)
    }

    @Test("wrapper forwards the budget reset to the current client")
    func wrapperForwardsReset() {
        let wrapper = GatewayClientWrapper()
        wrapper.client.setReconnectAttemptForTesting(5)
        wrapper.resetReconnectBudget(force: true)
        #expect(wrapper.client.snapshotForDebug.reconnectAttempt == 0)
    }
}

/// Regression tests for "still just hanging on Connecting…".
///
/// #178's budget reset was unconditional, and both macOS window focus
/// (`scenePhase` flips on focus, not just launch) and every `connectIfNeeded`
/// called it. Against an unreachable harness the counter was therefore zeroed
/// faster than it could climb, `maxReconnectAttempts` was never reached, and the
/// client retried at the 30s ceiling forever — publishing `.reconnecting` each
/// time, which the wrapper collapsed into `isConnecting`, so every surface read
/// a motionless "Connecting…".
///
/// The reset is now success-gated: it applies only if a socket actually opened
/// since the last grant. #178's case (a flaky link that does come back) still
/// works because each recovery earns the next budget.
@Suite("Reconnect budget is success-gated")
@MainActor
internal struct GatewayReconnectSuccessGateTests {

    private func makeClient() -> GatewayClient {
        // Port 9 (discard) — never dialed; every test tears the client down
        // before a backoff timer can fire.
        GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
    }

    @Test("an ambient reset is ignored when no connection ever succeeded")
    internal func ambientResetIgnoredWithoutSuccess() {
        let client = makeClient()
        client.setReconnectAttemptForTesting(4)

        // Window focus / foreground with a harness that has never opened.
        client.resetReconnectBudget()

        // The counter must survive, or the cap is unreachable and the loop
        // never terminates — the exact bug.
        #expect(client.snapshotForDebug.reconnectAttempt == 4)
        client.disconnect()
    }

    @Test("an ambient reset applies once a socket has actually opened")
    internal func ambientResetAppliesAfterSuccess() {
        let client = makeClient()
        client.markConnectedForTesting()
        client.setReconnectAttemptForTesting(4)

        client.resetReconnectBudget()

        // #178's scenario: the link came back, so the next flaky stretch gets a
        // full set of retries again.
        #expect(client.snapshotForDebug.reconnectAttempt == 0)
        client.disconnect()
    }

    @Test("one success grants one budget, not an unlimited supply")
    internal func successGrantsExactlyOneBudget() {
        let client = makeClient()
        client.markConnectedForTesting()

        client.resetReconnectBudget()
        client.setReconnectAttemptForTesting(7)
        // A second ambient reset with no intervening success must not apply —
        // otherwise repeated window focus still zeroes the counter forever.
        client.resetReconnectBudget()

        #expect(client.snapshotForDebug.reconnectAttempt == 7)
        client.disconnect()
    }

    @Test("an unreachable harness reaches the cap and stops with a terminal error")
    internal func unreachableHarnessTerminates() {
        let client = makeClient()

        // Walk the real state machine to the cap, interleaving the ambient reset
        // that used to keep it alive. Each disconnect must advance the counter.
        for expected in 1...GatewayClient.maxReconnectAttempts {
            client.resetReconnectBudget()  // window focus — must not help
            client.handleDisconnectForTesting(reason: "connection refused")
            #expect(client.snapshotForDebug.reconnectAttempt == expected)
            // The scheduled attempt is "in flight" as far as the state machine
            // is concerned; clear the flag so the next failure can schedule,
            // which is what openWebSocket does when the timer fires.
            client.clearReconnectScheduleForTesting()
        }

        // Cap reached: the next failure is terminal rather than a further retry.
        client.resetReconnectBudget()
        client.handleDisconnectForTesting(reason: "connection refused")
        guard case .error(let message) = client.connectionState else {
            Issue.record("expected a terminal .error at the cap, got \(client.connectionState)")
            client.disconnect()
            return
        }
        // The message names the host — the usual cause is an address that isn't
        // routable, so an opaque "connection lost" sends the user nowhere.
        #expect(message.contains("127.0.0.1"))
        client.disconnect()
    }

    @Test("a FAILED FIRST CONNECT schedules a retry instead of dying in .error")
    internal func failedFirstConnectSchedulesRetry() {
        // The bug that outlived three attempted fixes, because every one of them
        // targeted machinery downstream of this point.
        //
        // A socket that never opens produced `.error` with reconnectAttempt=0
        // and nothing scheduled: `receiveLoop` special-cased `.connecting` into
        // a bare `.error`, and the `didCompleteWithError` delegate merely logged
        // -1004 and returned. Auto-reconnect only ever armed after a SUCCESSFUL
        // connection, so the first-connect failure — the common case, a harness
        // that is unreachable or not yet listening — was permanently terminal.
        // The UI showed "Connecting…" throughout because the wrapper's
        // connectTask was still awaiting, holding isConnecting true.
        //
        // Measured before the fix: state reached error("Could not connect to the
        // server.") at 17.3s and never moved again. After: .reconnecting(1) at
        // 17.4s, .reconnecting(2) at 30.7s.
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")

        // Enter .connecting exactly as connect() does, WITHOUT a socket ever
        // opening, then deliver the failure a dead dial produces.
        client.beginConnectingForTesting()
        guard case .connecting = client.connectionState else {
            Issue.record("expected .connecting, got \(client.connectionState)")
            return
        }
        client.handleDisconnectForTesting(reason: "Could not connect to the server.")

        // Must schedule a retry, not park in a terminal state.
        guard case .reconnecting(let attempt) = client.connectionState else {
            Issue.record(
                "a failed first connect must schedule a retry, got \(client.connectionState)"
            )
            client.disconnect()
            return
        }
        #expect(attempt == 1)
        #expect(client.snapshotForDebug.reconnectAttempt == 1)
        client.disconnect()
    }

    @Test("the connect wait outlasts the handshake timeout")
    internal func connectWaitOutlastsHandshake() {
        // THE bug behind "Connecting, connecting, connecting…". The wait was 12s
        // against a 15s handshake, so a dial that was still legitimately in
        // progress was declared failed; connectWithRetry then rebuilt the
        // transport with a fresh client (a new `connect` event, counter back to
        // 0) and the real failure landed on a client nobody was listening to.
        // Measured against a black-holed host, URLSession reported -1004 at
        // 12.32s — 0.32s after the old wait expired.
        #expect(GatewayClientWrapper.connectWaitTimeout > GatewayClient.handshakeTimeout)
        // Enough headroom that the callback's own slack can't re-open the race.
        #expect(GatewayClientWrapper.connectWaitTimeout - GatewayClient.handshakeTimeout >= 3)
    }

    @Test("reconnecting is not reported as a plain first-time connect")
    internal func reconnectingIsDistinguishable() {
        // The display half of the bug: .connecting and .reconnecting both set
        // isConnecting, so the toolbar/menu bar/wiki showed the same
        // "Connecting…" whether it was a first dial or attempt 9 of a doomed
        // loop. reconnectAttempt carries the difference.
        #expect(GatewayClient.ConnectionState.connecting.statusLabel == "Connecting…")
        #expect(GatewayClient.ConnectionState.reconnecting(attempt: 9).statusLabel
                == "Reconnecting (attempt 9)…")
    }
}

@Suite("Health probe URL")
struct HealthProbeURLTests {

    @Test("Probe keeps the gateway's port — dropping it dialed strangers on :80")
    func keepsPort() {
        let url = GatewayClient.healthProbeURL(for: URL(string: "ws://127.0.0.1:8642/v1/ws")!)
        #expect(url?.absoluteString == "http://127.0.0.1:8642/health")
    }

    @Test("ws→http and wss→https scheme mapping")
    func schemes() {
        #expect(GatewayClient.healthProbeURL(for: URL(string: "wss://gw.example.com/v1/ws")!)?.absoluteString
                == "https://gw.example.com/health")
        #expect(GatewayClient.healthProbeURL(for: URL(string: "ws://192.168.1.7:9000/v1/ws")!)?.scheme == "http")
    }

    @Test("Query stripped, path replaced")
    func pathAndQuery() {
        let url = GatewayClient.healthProbeURL(for: URL(string: "wss://gw.example.com:4443/v1/ws?token=x")!)
        #expect(url?.absoluteString == "https://gw.example.com:4443/health")
    }
}

/// A slow `wiki.scan` used to leave the pane on "Loading…" forever because
/// `call` never armed a timeout. It now fails with `.timedOut`; this locks the
/// user-facing message (what the surface shows on a wedged gateway) and that a
/// call with no connection still fails fast rather than waiting out the timer.
@Suite("Gateway call timeout")
@MainActor
internal struct GatewayCallTimeoutTests {

    @Test("timedOut names the method and elapsed seconds")
    internal func timedOutMessage() {
        let error = GatewayError.timedOut(method: "wiki.scan", seconds: 30)
        #expect(error.errorDescription == "wiki.scan timed out after 30s")
    }

    @Test("A call with no socket fails fast, before the timeout can arm")
    internal func notConnectedBeatsTimeout() async {
        // Port 9 (discard) — never dialed; the client has no webSocketTask, so
        // call() must throw .notConnected immediately regardless of timeout.
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
        await #expect(throws: GatewayError.self) {
            _ = try await client.call("wiki.scan", timeout: 30)
        }
        client.disconnect()
    }
}

/// Beachball hardening: hot-path RPCs (send / resume / create) go through
/// `callWithRetry`, which reconnects and retries once ONLY on `.timedOut`
/// (the half-open-socket signature). Any other error — including the
/// no-connection case — must propagate immediately without a spurious retry
/// or reconnect, so a genuinely-down gateway still fails fast instead of
/// spinning.
@Suite("Gateway hot-path retry")
@MainActor
internal struct GatewayHotPathRetryTests {

    @Test("liveness probe continuation resolves exactly once")
    internal func livenessProbeResumesOnce() async {
        let result = await withCheckedContinuation { continuation in
            let completion = LivenessProbeCompletion(continuation)
            completion.resume(returning: true)
            completion.resume(returning: false)
        }
        #expect(result)
    }

    @Test("callWithRetry fails fast on a non-timeout error (no socket → no retry)")
    internal func failsFastWithoutSocket() async {
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
        // No webSocketTask → callWithRetry's inner call throws .notConnected,
        // which is not .timedOut, so it must surface at once (not reconnect).
        await #expect(throws: GatewayError.self) {
            _ = try await client.callWithRetry("prompt.submit")
        }
        #expect(client.snapshotForDebug.reconnectAttempt == 0)
        client.disconnect()
    }

    @Test("liveness check is a no-op when not connected")
    internal func livenessNoopWhenDisconnected() async {
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
        // Disconnected → no socket to probe; must return without arming a
        // reconnect (the wake-path guard only fires on a live-looking socket).
        await client.verifyLivenessOrReconnect(timeout: 1)
        #expect(client.snapshotForDebug.reconnectAttempt == 0)
        client.disconnect()
    }

    @Test("hot-path timeout is bounded and well under the 15s ping interval")
    internal func hotPathTimeoutIsBounded() {
        // Must trip before the ping timer's ~15s so a wedged send doesn't wait
        // on the keepalive to notice the dead socket.
        #expect(GatewayClient.hotPathTimeout > 0)
        #expect(GatewayClient.hotPathTimeout < 15)
    }
}
