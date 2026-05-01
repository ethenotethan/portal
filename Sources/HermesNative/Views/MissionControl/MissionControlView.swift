import SwiftUI

/// Mission Control — the navigation-first view of all running agent sessions.
/// Shows a grid of session cards with live status, spawn tree depth, and cost.
/// Tap a card to drill into the session explorer.
struct MissionControlView: View {
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var selectedSessionID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            if let sessionID = selectedSessionID,
               let tree = spawnTreeStore.sessions.first(where: { $0.sessionID == sessionID }) {
                SessionExplorerView(tree: tree)
                    .environmentObject(gatewayClientWrapper)
            } else {
                emptyDetail
            }
        }
        #if os(macOS)
        .navigationSplitViewStyle(.balanced)
        #endif
        .navigationTitle("Mission Control")
        .task {
            await sessionList.refreshSessions()
        }
        .refreshable {
            await sessionList.refreshSessions()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSessionID) {
            // Connection health
            Section("Gateway") {
                connectionStatusRow
            }

            // Active sessions
            Section("Sessions") {
                ForEach(sessionList.sessions) { session in
                    SessionMissionCard(
                        session: session,
                        tree: spawnTreeStore.sessions.first(where: { $0.sessionID == session.id }),
                        isActive: session.id == selectedSessionID
                    )
                    .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sessionList.sessions.isEmpty && !sessionList.isLoading {
                Text("No sessions")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Connection Status

    private var connectionStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(gatewayClientWrapper.isConnected ? Theme.success : Theme.warning)
                .frame(width: 8, height: 8)

            Text(gatewayClientWrapper.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let status = spawnTreeStore.delegationStatus {
                Text("\(status.activeSubagents) agents")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Empty Detail

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a session to explore")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap a session in the sidebar to see its spawn tree, tool calls, and live transcript.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session Mission Card

/// A card in the sidebar representing one agent session with live status.
struct SessionMissionCard: View {
    let session: Session
    let tree: SessionTree?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            statusDot

            VStack(alignment: .leading, spacing: 3) {
                // Title
                Text(session.title ?? session.source ?? "Session")
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                // Metadata
                HStack(spacing: 6) {
                    if let tree, tree.nodeCount > 1 {
                        Label("\(tree.nodeCount)", systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                    }
                    if let tree, tree.isRunning {
                        Label("running", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    if let tree, tree.totalCost > 0 {
                        Text(String(format: "$%.4f", tree.totalCost))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if session.messageCount > 0 {
                        Text("\(session.messageCount) msgs")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let source = session.source {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Running pulse
            if tree?.isRunning == true {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .modifier(PulseEffect())
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        let nodeStatus = tree?.root.status ?? .queued
        Image(systemName: nodeStatus.iconName)
            .font(.caption)
            .foregroundStyle(colorForStatus(nodeStatus))
    }
}

// MARK: - Status Colors

func colorForStatus(_ status: NodeStatus) -> Color {
    switch status {
    case .queued:      .secondary
    case .running:     .blue
    case .completed:   .green
    case .failed:      .red
    case .interrupted: .orange
    }
}

// MARK: - Pulse Animation

struct PulseEffect: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

#Preview {
    MissionControlView()
        .environmentObject(SessionListViewModel())
        .environmentObject(SpawnTreeStore())
        .environmentObject(GatewayClientWrapper())
        .frame(width: 900, height: 700)
}
