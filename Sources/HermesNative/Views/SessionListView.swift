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
    var onCreateSession: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    @State private var mySessionsCollapsed = false
    @State private var cronSessionsCollapsed = false
    @State private var otherSessionsCollapsed = false
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    private var mySessions: [Session] {
        sessionList.sessions.filter { $0.isOwned && !$0.isArchived }
    }

    private var archivedSessions: [Session] {
        sessionList.sessions.filter { $0.isOwned && $0.isArchived }
    }

    private var cronSessions: [Session] {
        sessionList.sessions.filter { $0.source?.lowercased() == "cron" }
    }

    private var otherSessions: [Session] {
        sessionList.sessions.filter { !$0.isOwned && $0.source?.lowercased() != "cron" }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                #if os(macOS)
                sidebarToolbarRow
                    .frame(height: 40)
                #endif

                sidebarHeader

                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)

                List(selection: $sessionList.activeSessionID) {
                // My Sessions
                Section {
                if !mySessionsCollapsed {
                    if mySessions.isEmpty {
                        VStack(spacing: 8) {
                            Text("No sessions yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Button("Start New Chat") {
                                onCreateSession?()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("startNewChatButton")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(mySessions) { session in
                            SessionRowView(
                                title: sessionList.titleForSession(session),
                                subtitle: sessionList.subtitleForOwnedSession(session, skin: activeSkin),
                                source: nil,
                                isActive: session.id == chatViewModel.currentSessionID,
                                isOwned: true
                            )
                            .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
                            .tag(session.id)
                            .contextMenu {
                                Button {
                                    onMissionControl?(session.id)
                                } label: {
                                    Label("Mission Control", systemImage: "network")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    sessionList.archiveSession(id: session.id)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                            #if os(iOS)
                            .swipeActions(edge: .leading) {
                                Button {
                                    onMissionControl?(session.id)
                                } label: {
                                    Label("Mission Control", systemImage: "network")
                                }
                                .tint(Theme.accent)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sessionList.archiveSession(id: session.id)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                            #endif
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
                }
            } header: {
                collapsibleHeader(
                    title: "My Sessions",
                    icon: "bubble.left.fill",
                    count: mySessions.count,
                    isCollapsed: mySessionsCollapsed
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mySessionsCollapsed.toggle()
                    }
                }
            }

            // Archived
            if !archivedSessions.isEmpty {
                Section {
                    if sessionList.showArchived {
                        ForEach(archivedSessions) { session in
                            SessionRowView(
                                title: sessionList.titleForSession(session),
                                subtitle: sessionList.subtitleForOwnedSession(session, skin: activeSkin),
                                source: nil,
                                isActive: session.id == chatViewModel.currentSessionID,
                                isOwned: true,
                                isArchived: true
                            )
                            .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
                            .tag(session.id)
                            .contextMenu {
                                Button {
                                    sessionList.unarchiveSession(id: session.id)
                                } label: {
                                    Label("Unarchive", systemImage: "arrow.up.archive")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    Task { try? await sessionList.deleteArchivedSession(id: session.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #if os(iOS)
                            .swipeActions(edge: .leading) {
                                Button {
                                    sessionList.unarchiveSession(id: session.id)
                                } label: {
                                    Label("Unarchive", systemImage: "arrow.up.archive")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { try? await sessionList.deleteArchivedSession(id: session.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #endif
                        }
                    }
                } header: {
                    collapsibleHeader(
                        title: "Archived",
                        icon: "archivebox",
                        count: archivedSessions.count,
                        isCollapsed: !sessionList.showArchived
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sessionList.showArchived.toggle()
                        }
                    }
                }
            }

            // Cron Sessions
            if !cronSessions.isEmpty {
                Section {
                    if !cronSessionsCollapsed {
                        ForEach(cronSessions) { session in
                            SessionRowView(
                                title: sessionList.titleForSession(session),
                                subtitle: sessionList.subtitleForSession(session),
                                source: session.source,
                                isActive: session.id == chatViewModel.currentSessionID,
                                isOwned: false,
                                sessionStatus: session.status
                            )
                            .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
                            .tag(session.id)
                        }
                    }
                } header: {
                    collapsibleHeader(
                        title: "Cron Sessions",
                        icon: "clock.fill",
                        count: cronSessions.count,
                        isCollapsed: cronSessionsCollapsed
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            cronSessionsCollapsed.toggle()
                        }
                    }
                }
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
                                isActive: session.id == chatViewModel.currentSessionID,
                                isOwned: false
                            )
                            .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
                            .tag(session.id)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
                .overlay {
                    if sessionList.sessions.isEmpty && !sessionList.isLoading {
                        emptyState
                    }
                }
                .refreshable {
                    await sessionList.refreshSessions()
                }
                .task {
                    await sessionList.refreshSessions()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    #if os(macOS)
    private var sidebarToolbarRow: some View {
        HStack(alignment: .center, spacing: 0) {
            // Reserve the traffic-light strip so the app-owned sidebar toggle
            // sits on the same vertical center/baseline as the window controls.
            Color.clear
                .frame(width: 68, height: 28)

            Spacer(minLength: 0)

            Button(action: { onToggleSidebar?() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle Sidebar")
            .accessibilityIdentifier("sidebarToggleButton")
        }
        .frame(height: 40)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
    }
    #endif

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiary)

            HStack(spacing: 8) {
                sidebarHeaderButton(
                    icon: "plus",
                    title: "New Session",
                    accessibilityLabel: "New Session",
                    accessibilityID: "newSessionButton",
                    isPrimary: true,
                    action: { onCreateSession?() }
                )

                sidebarHeaderButton(
                    icon: "clock.badge.checkmark",
                    title: "Cron",
                    accessibilityLabel: "Open Cron Jobs",
                    accessibilityID: "panelToggleButton",
                    isPrimary: false,
                    action: { onOpenPanel?() }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
    }

    private func sidebarHeaderButton(
        icon: String,
        title: String,
        accessibilityLabel: String,
        accessibilityID: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .frame(maxWidth: isPrimary ? .infinity : nil, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPrimary ? Theme.primary : Theme.secondary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPrimary ? Theme.accent : Theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isPrimary ? Theme.accent.opacity(0.65) : Theme.border, lineWidth: 1)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityID)
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

}

// MARK: - Session Row

private extension View {
    func sessionListRowStyle(isActive: Bool) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.22) : Color.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            )
    }
}

struct SessionRowView: View {
    let title: String
    let subtitle: String?
    let source: String?     // nil for owned sessions (don't show source badge)
    let isActive: Bool
    let isOwned: Bool
    var isArchived: Bool = false
    var sessionStatus: SessionStatus? = nil

    var body: some View {
        HStack(spacing: 10) {
            // Source/platform icon or ownership indicator
            iconView
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                        .foregroundStyle(isArchived ? .secondary : .primary)

                    // Pulsing green dot for active sessions
                    if sessionStatus == .active {
                        PulsingDot(color: Theme.success)
                    }
                }

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
            } else if isArchived {
                Image(systemName: "archivebox")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            } else if !isOwned {
                // Observer badge for non-owned sessions
                Image(systemName: "eye")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        if isArchived { return .secondary }
        return isOwned ? Theme.accent : .secondary
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
            case "cron":     Image(systemName: "clock.fill")
            default:         Image(systemName: "bubble.left.fill")
            }
        }
    }
}

// MARK: - Pulsing Activity Dot

struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

#Preview {
    SessionListView()
        .environmentObject(SessionListViewModel())
        .environmentObject(ChatViewModel())
        .environmentObject(GatewayClientWrapper())
        .frame(width: 280, height: 500)
}
