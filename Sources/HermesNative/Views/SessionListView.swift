import SwiftUI

/// Sidebar list of sessions split into two tiers:
/// - "My Sessions" — created by this app, full control (chat, Mission Control)
/// - "Other Sessions" — from Telegram/TUI/etc, read-only observer mode
struct SessionListView: View {
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    /// Called on long-press with the session ID to open Mission Control.
    var onMissionControl: ((String) -> Void)?
    /// Called when tapping a non-owned session to open observer view.
    var onObserve: ((String) -> Void)?

    @State private var otherSessionsCollapsed = false

    private var mySessions: [Session] {
        sessionList.sessions.filter { $0.isOwned }
    }

    private var otherSessions: [Session] {
        sessionList.sessions.filter { !$0.isOwned }
    }

    var body: some View {
        List(selection: $sessionList.activeSessionID) {
            // My Sessions
            Section {
                if mySessions.isEmpty {
                    Text("No sessions yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(mySessions) { session in
                        SessionRowView(
                            title: sessionList.titleForSession(session),
                            subtitle: sessionList.subtitleForSession(session),
                            source: nil,  // Don't show source for own sessions
                            isActive: session.id == chatViewModel.currentSessionID,
                            isOwned: true
                        )
                        .tag(session.id)
                        .contextMenu {
                            Button {
                                onMissionControl?(session.id)
                            } label: {
                                Label("Mission Control", systemImage: "network")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let session = mySessions[index]
                            Task {
                                try? await sessionList.closeSession(id: session.id)
                            }
                        }
                    }
                }
            } header: {
                sectionHeader(title: "My Sessions", icon: "bubble.left.fill")
            }

            // Other Sessions (read-only, collapsible)
            Section {
                if !otherSessionsCollapsed {
                    if otherSessions.isEmpty {
                        Text("No other sessions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(otherSessions) { session in
                            SessionRowView(
                                title: sessionList.titleForSession(session),
                                subtitle: sessionList.subtitleForSession(session),
                                source: session.source,
                                isActive: false,  // Can't "activate" other sessions
                                isOwned: false
                            )
                            .onTapGesture {
                                onObserve?(session.id)
                            }
                        }
                    }
                }
            } header: {
                collapsibleHeader(
                    title: "Other Sessions",
                    icon: "eye",
                    count: otherSessions.count,
                    isCollapsed: otherSessionsCollapsed
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        otherSessionsCollapsed.toggle()
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if sessionList.sessions.isEmpty && !sessionList.isLoading {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createAndSwitchSession() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .cancellationAction) {
                EditButton()
            }
            #endif
        }
        .refreshable {
            await sessionList.refreshSessions()
        }
        .task {
            await sessionList.refreshSessions()
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
        }
    }

    private func collapsibleHeader(title: String, icon: String, count: Int, isCollapsed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
            Text("(\(count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Sessions")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap + to start a new chat")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createAndSwitchSession() async {
        guard case .connected = gatewayClientWrapper.client.connectionState else { return }
        do {
            await chatViewModel.createSession()
            if let sid = chatViewModel.currentSessionID {
                // Register the session as owned (appears in "My Sessions" immediately)
                sessionList.registerOwnedSession(shortHexID: sid)
            }
        } catch {
            chatViewModel.error = error.localizedDescription
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let title: String
    let subtitle: String?
    let source: String?     // nil for owned sessions (don't show source badge)
    let isActive: Bool
    let isOwned: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Source/platform icon or ownership indicator
            iconView
                .font(.body)
                .foregroundStyle(isOwned ? Theme.accent : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            } else if !isOwned {
                // Observer badge for non-owned sessions
                Image(systemName: "eye")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var iconView: some View {
        if isOwned {
            Image(systemName: "bubble.left.fill")
        } else {
            switch source?.lowercased() {
            case "telegram": Image(systemName: "paperplane.fill")
            case "discord":  Image(systemName: "headphones")
            case "cli":      Image(systemName: "terminal.fill")
            case "tui":      Image(systemName: "terminal.fill")
            case "slack":    Image(systemName: "number.square.fill")
            case "matrix":   Image(systemName: "rectangle.3.group.fill")
            case "whatsapp": Image(systemName: "phone.fill")
            case "webhook":  Image(systemName: "arrow.triangle.branch")
            default:         Image(systemName: "bubble.left.fill")
            }
        }
    }
}

#Preview {
    SessionListView()
        .environmentObject(SessionListViewModel())
        .environmentObject(ChatViewModel())
        .environmentObject(GatewayClientWrapper())
        .frame(width: 280, height: 500)
}
