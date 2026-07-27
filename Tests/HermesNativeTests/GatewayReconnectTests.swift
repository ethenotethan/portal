import Testing
import Foundation
@testable import HermesNative

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

        // Foreground / explicit user action grants a fresh budget…
        client.resetReconnectBudget()
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
        wrapper.resetReconnectBudget()
        #expect(wrapper.client.snapshotForDebug.reconnectAttempt == 0)
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
