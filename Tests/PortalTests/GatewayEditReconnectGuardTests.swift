import Foundation
import Testing

/// Pins the reconnect-on-edit path for in-place gateway edits, which is a
/// structural property of ContentView's body — the same reason
/// `CanvasRelayoutGuardTests` reads source instead of constructing views.
///
/// **The hole this closes, from a live incident.** The user's stored gateway
/// URL was wrong (a refused Keychain read had dropped the app onto the
/// localhost default). They typed the correct address into Settings — and
/// nothing happened. `updateGateway` and the URL field's `didSet` persist the
/// new value, but every reconnect observer keyed on `activeGatewayID`, which
/// an in-place edit never changes: `handleGatewaySwitch` didn't run,
/// `.onChange(of: settings.savedGateways)` only refreshes the persona, and
/// "Make Active" on the already-active entry early-returns in
/// `selectGateway`. The transport stayed dialed at the old address while
/// Settings displayed the new one, and the only recoveries were an app
/// restart or switching to a *different* gateway and back.
@Suite("Gateway edit reconnect guards")
internal struct GatewayEditReconnectGuardTests {

    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources/Portal")

    private static func contentViewSource() throws -> String {
        try String(
            contentsOf: sourcesRoot.appendingPathComponent("Views/ContentView.swift"),
            encoding: .utf8
        )
    }

    @Test("editing the live gateway URL triggers a reconnect")
    internal func urlEditsAreObserved() throws {
        let source = try Self.contentViewSource()
        #expect(
            source.contains(".onChange(of: settings.gatewayURL)"),
            """
            ContentView must observe settings.gatewayURL. An in-place edit of \
            the active gateway is invisible to every other reconnect trigger \
            (activeGatewayID doesn't change), so without this observer a \
            corrected address never reaches the wire until app restart.
            """
        )
    }

    @Test("editing the live API key triggers a reconnect")
    internal func apiKeyEditsAreObserved() throws {
        let source = try Self.contentViewSource()
        #expect(
            source.contains(".onChange(of: settings.apiKey)"),
            "Same in-place-edit hole as the URL — a corrected key must redial too."
        )
    }

    @Test("the reconnect is debounced, not per-keystroke")
    internal func reconnectIsDebounced() throws {
        let source = try Self.contentViewSource()
        // The Settings/Onboarding text fields assign gatewayURL on every
        // keystroke. Each edit must cancel the pending dial and reschedule;
        // dialing per keystroke would spray half-typed addresses at the
        // network and tear the transport down mid-edit.
        #expect(
            source.contains("settingsReconnectTask?.cancel()"),
            "scheduleSettingsReconnect must cancel the pending task before rescheduling."
        )
        #expect(
            source.contains("func scheduleSettingsReconnect()"),
            "Both edit observers funnel through one debounced entry point."
        )
    }
}

/// Session-creation feedback must exist on BOTH platforms. It was
/// `#if os(iOS)` only, which made macOS creation silent in exactly the state
/// where feedback matters (create pressed during transport reconnect: the
/// task burns ~26s in connect retries invisibly, the error lands nowhere,
/// and re-presses are swallowed by the isCreatingSession guard — "the New
/// Session button does nothing, existing sessions work").
@Suite("Session creation feedback")
internal struct SessionCreationFeedbackTests {

    @Test("the creation status bar is not platform-gated")
    internal func statusBarIsCrossPlatform() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Portal/Views/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private var sessionCreationStatusBar"))
        let end = try #require(source.range(of: "accessibilityIdentifier(\"sessionCreationStatus\")"))
        let body = source[start.upperBound..<end.lowerBound]
        #expect(
            !body.contains("#if os("),
            "sessionCreationStatusBar must render on every platform — gating it made macOS creation failures invisible"
        )
        // And macOS actually mounts it: the sidebar overlay is the mount point.
        #expect(
            source.contains(".overlay(alignment: .bottom) {\n                        sessionCreationStatusBar"),
            "the macOS sidebar must dock the status bar — an unmounted view is as silent as a gated one"
        )
    }
}
