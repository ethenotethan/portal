import SwiftUI

/// Sidebar list of sessions — tap to resume, long-press for Mission Control, swipe to kill.
struct SessionListView: View {
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    /// Called on long-press with the session ID to open Mission Control.
    var onMissionControl: ((String) -> Void)? = nil

    var body: some View {
        List(selection: $sessionList.activeSessionID) {
            ForEach(sessionList.sessions) { session in
                SessionRowView(
                    title: sessionList.titleForSession(session),
                    subtitle: sessionList.subtitleForSession(session),
                    source: session.source,
                    hasKey: sessionList.keyForSession(id: session.id) != nil,
                    isActive: session.id == chatViewModel.currentSessionID
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
                    let session = sessionList.sessions[index]
                    Task {
                        try? await sessionList.closeSession(id: session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
            // Only create via chatViewModel — it syncs with sessionList via
            // the title onChange handler. Avoids double session.create RPC.
            await chatViewModel.createSession()
            if let sid = chatViewModel.currentSessionID {
                // Store the key locally for future resume
                if let key = gatewayClientWrapper.client.lastSessionKey {
                    sessionList.storeSessionKey(id: sid, key: key)
                }
                sessionList.selectSession(id: sid)
                // Refresh to pick up the new session in the list
                await sessionList.refreshSessions()
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
    let source: String?
    let hasKey: Bool      // Whether we can resume this session
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Source/platform icon
            sourceIcon
                .font(.body)
                .foregroundStyle(hasKey ? Theme.accent : .secondary)
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
            } else if !hasKey {
                // No key = can't resume, show lock
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var sourceIcon: some View {
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

#Preview {
    SessionListView()
        .environmentObject(SessionListViewModel())
        .environmentObject(ChatViewModel())
        .environmentObject(GatewayClientWrapper())
        .frame(width: 280, height: 500)
}
