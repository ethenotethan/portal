import SwiftUI
import Combine

// MARK: - Connection-state display helpers

/// How a backend's live `ConnectionState` should read in the UI: a color for
/// dots/labels, a human label, and whether it counts as "up". Shared by the
/// Harnesses sidebar dots and the per-harness Connection section so every
/// surface agrees on what green/amber/red means.
extension GatewayClient.ConnectionState {
    internal var statusColor: Color {
        switch self {
        case .connected: return Theme.success
        case .connecting, .reconnecting: return Theme.warning
        case .disconnected: return Theme.secondary
        case .error: return .red
        }
    }

    internal var statusLabel: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))…"
        case .disconnected: return "Offline"
        case .error(let message): return "Error: \(message)"
        }
    }

    internal var isUp: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Live status dot

/// A small colored dot reflecting a backend's live connection state. Observes
/// the backend's `connectionStatePublisher` so it repaints on connect/drop
/// without the enclosing view being an `@ObservedObject` of an existential.
/// A `nil` backend renders a dim "offline" dot (nothing is dialing this entry).
internal struct HarnessStatusDot: View {
    internal let backend: (any AgentBackend)?
    internal var diameter: CGFloat = 6

    @State private var state: GatewayClient.ConnectionState = .disconnected

    internal var body: some View {
        Circle()
            .fill(backend == nil ? Theme.secondary.opacity(0.4) : state.statusColor)
            .frame(width: diameter, height: diameter)
            .onReceive(statePublisher) { state = $0 }
    }

    private var statePublisher: AnyPublisher<GatewayClient.ConnectionState, Never> {
        backend?.connectionStatePublisher ?? Empty().eraseToAnyPublisher()
    }
}

// MARK: - Per-harness Connection section (macOS detail pane)

#if os(macOS)
/// The "Connection" block in a harness's settings pane: a live status row plus
/// a button into the full transport diagnostics (`GatewayDebugPanelView`).
///
/// Resolves the live backend for this entry via the wrapper — creating
/// nothing — so an idle harness reads "Offline" with a kind-specific hint for
/// how to bring it online, rather than silently spinning up a socket.
internal struct HarnessConnectionSection: View {
    internal let gateway: SavedGateway

    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper

    @State private var state: GatewayClient.ConnectionState = .disconnected
    @State private var showLog = false

    private var backend: (any AgentBackend)? {
        gatewayClientWrapper.liveClient(for: gateway, isActive: settings.isActive(gateway))
    }

    /// RTT is only meaningful for the active home gateway — that's the one the
    /// wrapper keeps a live keepalive reading for. Sidecars surface theirs in
    /// the full connection log instead.
    private var showsRTT: Bool {
        gateway.kind == .hermes && settings.isActive(gateway)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection")
                .font(.headline)

            HStack(spacing: 8) {
                HarnessStatusDot(backend: backend, diameter: 8)
                Text(backend == nil ? offlineLabel : state.statusLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(backend == nil ? Theme.secondary : Theme.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if showsRTT, let rtt = gatewayClientWrapper.lastPingRTT {
                    Text("\(Int(rtt * 1000)) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .onReceive(statePublisher) { state = $0 }

            if let hint = offlineHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let client = backend as? GatewayClient {
                Button {
                    showLog = true
                } label: {
                    Label("View connection log", systemImage: "wave.3.right.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .sheet(isPresented: $showLog) {
                    GatewayDebugPanelView(client: client)
                        .frame(minWidth: 560, minHeight: 620)
                }
            }
        }
    }

    private var statePublisher: AnyPublisher<GatewayClient.ConnectionState, Never> {
        backend?.connectionStatePublisher ?? Empty().eraseToAnyPublisher()
    }

    private var offlineLabel: String { "Offline" }

    /// Explains why an entry with no live client is offline and how to connect
    /// it — the transport for each kind only comes up under a specific trigger.
    private var offlineHint: String? {
        guard backend == nil else { return nil }
        switch gateway.kind {
        case .hermes:
            return "Make this harness active to connect its gateway socket."
        case .hermesStandard:
            return "Focus this harness to connect its chat sidecar."
        case .centaur:
            return "Connects when a session opens on this harness."
        }
    }
}
#endif
