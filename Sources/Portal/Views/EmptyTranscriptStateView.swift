import SwiftUI

/// What an empty transcript says instead of nothing (#258).
///
/// An external tester's read of a cold launch: "it doesn't really tell you
/// anything… this is the kind of thing that would make less technical people
/// uncomfortable." The pane was literally blank — both transcript hosts
/// (`ConversationPanel` on the macOS canvas, `ChatView.messageListArea` on
/// iOS) render rows and nothing else, so before the first message the user
/// stares at silence while the app connects, retries, or quietly fails. A
/// launch that dialed a wrong address looked identical to one that worked.
///
/// This view narrates that gap. It renders only while the transcript is empty
/// and nothing is streaming, and says exactly one of four things, in the order
/// a launch actually passes through them: connecting → couldn't connect →
/// preparing the session → ready, say something. The disconnected state is the
/// load-bearing one: it names the address it failed to reach (a wrong address
/// is *visible* instead of indistinguishable from a dead harness) and offers a
/// retry that goes through the same rewire-safe path as Settings edits.
internal struct EmptyTranscriptStateView: View {
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper

    /// The one thing the empty pane should say right now.
    ///
    /// Pure and order-sensitive so it is testable: `connecting` outranks
    /// `disconnected` (a dial in flight is progress, not failure), and both
    /// outrank session setup (no session exists without a transport).
    internal enum LaunchPaneState: Equatable {
        case connecting
        case disconnected
        case preparingSession
        case readyToChat

        internal static func derive(
            isConnected: Bool,
            isConnecting: Bool,
            isSessionReady: Bool
        ) -> LaunchPaneState {
            if isConnecting { return .connecting }
            if !isConnected { return .disconnected }
            if !isSessionReady { return .preparingSession }
            return .readyToChat
        }
    }

    private var state: LaunchPaneState {
        .derive(
            isConnected: gatewayClientWrapper.isConnected,
            isConnecting: gatewayClientWrapper.isConnecting,
            isSessionReady: chatViewModel.isSessionReady
        )
    }

    /// "Harness" is meaningless to a first-time user; the entry's name (or its
    /// host) is what they typed and what they can check.
    private var gatewayLabel: String {
        if let gateway = settings.focusedGateway { return gateway.displayName }
        if let host = URL(string: settings.gatewayURL)?.host { return host }
        return settings.gatewayURL
    }

    internal var body: some View {
        VStack(spacing: 10) {
            switch state {
            case .connecting:
                PortalProgressView()
                Text("Connecting to \(gatewayLabel)…")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)

            case .disconnected:
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.tertiary)
                Text("Not connected")
                    .font(.headline)
                    .foregroundStyle(Theme.secondary)
                Text("Couldn't reach \(settings.gatewayURL). Check that the address is right in Settings and that the harness is running.")
                    .font(.callout)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") {
                    // Routed through ContentView's debounced reconnect rather
                    // than dialing the wrapper directly: connecting can swap
                    // the wrapper's inner client, and only ContentView can
                    // re-wire the view models to the replacement. A direct
                    // dial from here would leave the chat pipeline pointed at
                    // the dead transport — the exact stale-wiring failure the
                    // reconnect path exists to prevent.
                    NotificationCenter.default.post(name: .hermesReconnectRequested, object: nil)
                }
                .buttonStyle(.bordered)

            case .preparingSession:
                PortalProgressView()
                Text("Connected to \(gatewayLabel) — setting up your session…")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)

            case .readyToChat:
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.tertiary)
                Text("Connected to \(gatewayLabel)")
                    .font(.headline)
                    .foregroundStyle(Theme.secondary)
                Text("Type a message below to start.")
                    .font(.callout)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }
}
