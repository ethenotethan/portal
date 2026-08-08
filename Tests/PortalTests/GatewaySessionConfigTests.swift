import Testing
import Foundation
@testable import Portal

/// Regression coverage for "it just says Connecting but it never actually
/// opens."
///
/// `openWebSocket` configured its session with `waitsForConnectivity = true`.
/// Against a host that is unreachable — or reachable but not serving, which
/// black-holes the SYN with no RST, the normal failure for a tailnet peer that
/// is up without the harness running — URLSession does not treat that as an
/// error. It treats it as "no network path yet" and waits silently for one:
/// **no delegate callback fires at all**. So `handleDisconnect` never runs, no
/// `.error` is published, no reconnect is scheduled, and the client parks in
/// `.connecting`, which every surface renders as "Connecting…", until
/// `timeoutIntervalForResource` finally expires five minutes later.
///
/// Measured against an unreachable `100.64.0.1:8642`: with `true`, no callback
/// after 25s and the task still `.running`; with `false`, `-1004 Could not
/// connect to the server` in about a second, which drives the existing
/// `handleDisconnect` → `.error` → backoff path correctly.
///
/// The bug is invisible to an ordinary unit test because it manifests as the
/// *absence* of a callback, so `makeSessionConfig` is a separate seam and these
/// tests assert the connectivity semantics directly.
@Suite("Gateway session config")
@MainActor
internal struct GatewaySessionConfigTests {

    @Test("waitsForConnectivity is off so an unreachable harness reports an error")
    internal func doesNotWaitForConnectivity() {
        // If this ever flips back to true, connect failures go silent again and
        // the UI shows "Connecting…" indefinitely.
        #expect(GatewayClient.makeSessionConfig().waitsForConnectivity == false)
    }

    @Test("the handshake timeout is bounded well under the 60s default")
    internal func handshakeTimeoutIsBounded() {
        let config = GatewayClient.makeSessionConfig()
        #expect(config.timeoutIntervalForRequest == GatewayClient.handshakeTimeout)
        // A black-holed host produces no RST, so only the timeout ends the
        // attempt. The stock 60s would be a full minute of "Connecting…".
        #expect(GatewayClient.handshakeTimeout <= 20)
        // Long enough that a slow-but-live tailnet handshake isn't cut off.
        #expect(GatewayClient.handshakeTimeout >= 5)
    }

    @Test("the resource timeout outlives the handshake timeout")
    internal func resourceTimeoutIsTheOuterBound() {
        let config = GatewayClient.makeSessionConfig()
        // The resource budget covers the whole long-lived socket, so it must not
        // be the thing that bounds the initial upgrade.
        #expect(config.timeoutIntervalForResource > config.timeoutIntervalForRequest)
    }

    @Test("pipelining stays off for the WebSocket upgrade")
    internal func pipeliningDisabled() {
        #expect(GatewayClient.makeSessionConfig().httpShouldUsePipelining == false)
    }

    @Test("each call hands back a fresh config, not shared mutable state")
    internal func configIsNotShared() {
        let first = GatewayClient.makeSessionConfig()
        let second = GatewayClient.makeSessionConfig()
        first.timeoutIntervalForRequest = 999
        #expect(second.timeoutIntervalForRequest == GatewayClient.handshakeTimeout)
    }
}
