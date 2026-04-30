import SwiftUI

/// Sidebar list of sessions — tap to resume, swipe to kill, button to create.
struct SessionListView: View {
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    var body: some View {
        List(selection: $sessionList.activeSessionID) {
            ForEach(sessionList.sessions) { session in
                SessionRowView(
                    title: sessionList.titleForSession(session),
                    subtitle: session.model,
                    isRunning: session.isRunning,
                    isActive: session.id == chatViewModel.currentSessionID
                )
                .tag(session.id)
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
            let sid = try await sessionList.createSession()
            await chatViewModel.createSession()
            sessionList.selectSession(id: sid)
        } catch {
            chatViewModel.error = error.localizedDescription
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let title: String
    let subtitle: String?
    let isRunning: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(isRunning ? Theme.accent : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

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
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SessionListView()
        .environmentObject(SessionListViewModel())
        .environmentObject(ChatViewModel())
        .environmentObject(GatewayClientWrapper())
        .frame(width: 280, height: 500)
}
