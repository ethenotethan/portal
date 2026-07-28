import SwiftUI

/// Sidebar list of sessions split into two tiers:
/// - "My Sessions" — created by this app, full control
/// - "Other Sessions" — from Telegram/TUI/etc, opened read-only
/// Tapping any row selects it into the chat view.
struct SessionListView: View {
    @EnvironmentObject internal var sessionList: SessionListViewModel
    @EnvironmentObject internal var settings: SettingsViewModel

    public var currentSessionID: String?

    var onCreateSession: (() -> Void)?
    var onOpenPanel: (() -> Void)?

    @State private var mySessionsCollapsed = false
    @State private var cronSessionsCollapsed = false
    @State private var otherSessionsCollapsed = false
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    /// When a gateway is focused, filter the displayed sessions to only those
    /// that belong to it. Session-scoped (Centaur) gateways use the backend
    /// registry. The Hermes home gateway shows sessions with no registered
    /// backend (nil) plus any sessions explicitly mapped to its ID.
    private func gatewayFilter(_ session: Session) -> Bool {
        guard let focused = settings.focusedGateway else { return true }
        let backendID = SessionBackendRegistry.shared.backendID(for: session.id)
        if focused.kind.isSessionScoped {
            // Session-scoped gateway: show only its sessions
            return backendID == focused.id
        } else {
            // Hermes gateway: show sessions with no backend registration
            // (legacy / natively created) or mapped to this specific entry
            return backendID == nil || backendID == focused.id
        }
    }

    private var mySessions: [Session] {
        sessionList.sortedForSidebar(sessionList.sessions.filter { $0.isOwned && !$0.isArchived && gatewayFilter($0) })
    }

    private var archivedSessions: [Session] {
        sessionList.sortedForSidebar(sessionList.sessions.filter { $0.isOwned && $0.isArchived && gatewayFilter($0) })
    }

    private var cronSessions: [Session] {
        sessionList.sortedForSidebar(sessionList.sessions.filter { $0.source?.lowercased() == "cron" && gatewayFilter($0) })
    }

    private var otherSessions: [Session] {
        sessionList.sortedForSidebar(sessionList.sessions.filter { !$0.isOwned && $0.source?.lowercased() != "cron" && gatewayFilter($0) })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.background

            VStack(spacing: 0) {
                sidebarHeader

                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // My Sessions
                        sessionSection(
                            title: "My Sessions",
                            icon: "bubble.left.fill",
                            count: mySessions.count,
                            isCollapsed: mySessionsCollapsed,
                            onToggle: { mySessionsCollapsed.toggle() },
                            content: {
                                if mySessions.isEmpty {
                                    VStack(spacing: 8) {
                                        Text("Ready when you are ✨")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Button("Start First Chat") {
                                            onCreateSession?()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("startNewChatButton")
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                                } else {
                                    ForEach(mySessions) { session in
                                        mySessionRow(session: session)
                                    }
                                }
                            }
                        )

                        // Archived
                        if !archivedSessions.isEmpty {
                            sessionSection(
                                title: "Archived",
                                icon: "archivebox",
                                count: archivedSessions.count,
                                isCollapsed: !sessionList.showArchived,
                                onToggle: { sessionList.showArchived.toggle() },
                                content: {
                                    if sessionList.showArchived {
                                        ForEach(archivedSessions) { session in
                                            archivedSessionRow(session: session)
                                        }
                                    }
                                }
                            )
                        }

                        // Cron Sessions
                        if !cronSessions.isEmpty {
                            sessionSection(
                                title: "Cron Sessions",
                                icon: "clock.fill",
                                count: cronSessions.count,
                                isCollapsed: cronSessionsCollapsed,
                                onToggle: { cronSessionsCollapsed.toggle() },
                                content: {
                                    ForEach(cronSessions) { session in
                                        otherSessionRow(session: session)
                                    }
                                }
                            )
                        }

                        // Other Sessions
                        sessionSection(
                            title: "Other Sessions",
                            icon: "eye",
                            count: otherSessions.count,
                            isCollapsed: otherSessionsCollapsed,
                            onToggle: { otherSessionsCollapsed.toggle() },
                            content: {
                                if otherSessions.isEmpty {
                                    Text("No other sessions")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 20)
                                } else {
                                    ForEach(otherSessions) { session in
                                        otherSessionRow(session: session)
                                    }
                                }
                            }
                        )
                    }
                    .padding(.horizontal, 8)
                }
                .refreshable {
                    await sessionList.refreshSessions()
                }
                .task {
                    await sessionList.refreshSessions()
                }
                .overlay {
                    if sessionList.sessions.isEmpty && !sessionList.isLoading {
                        emptyState
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Row Builders

    @ViewBuilder
    private func mySessionRow(session: Session) -> some View {
        SessionRowView(
            title: sessionList.titleForSession(session),
            subtitle: sessionList.subtitleForOwnedSession(session, skin: activeSkin),
            source: nil,
            isActive: session.id == currentSessionID,
            isOwned: true,
            isPinned: session.isPinned,
            tags: session.tags,
            runState: session.displayRunState
        )
        .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
        .contentShape(Rectangle())
        .onTapGesture {
            sessionList.selectSession(id: session.id)
        }
        .contextMenu {
            Button {
                sessionList.togglePinned(id: session.id)
            } label: {
                Label(session.isPinned ? "Unpin Session" : "Pin Session",
                      systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            exportMarkdownButton(session: session)
            Divider()
            Button(role: .destructive) {
                sessionList.archiveSession(id: session.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    /// "Export Markdown" for any session with persisted local history —
    /// works without opening the session (macOS save panel only).
    @ViewBuilder
    private func exportMarkdownButton(session: Session) -> some View {
        #if os(macOS)
        if SessionListExport.canExport(sessionID: session.id) {
            Button {
                SessionListExport.exportMarkdown(
                    session: session,
                    title: sessionList.titleForSession(session),
                    gatewayName: nil
                )
            } label: {
                Label("Export Markdown", systemImage: "doc.plaintext")
            }
        }
        #endif
    }

    @ViewBuilder
    private func archivedSessionRow(session: Session) -> some View {
        SessionRowView(
            title: sessionList.titleForSession(session),
            subtitle: sessionList.subtitleForOwnedSession(session, skin: activeSkin),
            source: nil,
            isActive: session.id == currentSessionID,
            isOwned: true,
            isArchived: true,
            isPinned: session.isPinned,
            tags: session.tags,
            runState: session.displayRunState
        )
        .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
        .contentShape(Rectangle())
        .onTapGesture {
            sessionList.selectSession(id: session.id)
        }
        .contextMenu {
            Button {
                sessionList.togglePinned(id: session.id)
            } label: {
                Label(session.isPinned ? "Unpin Session" : "Pin Session",
                      systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Button {
                sessionList.unarchiveSession(id: session.id)
            } label: {
                Label("Unarchive", systemImage: "arrow.up.archive")
            }
            exportMarkdownButton(session: session)
            Divider()
            Button(role: .destructive) {
                Task { try? await sessionList.deleteArchivedSession(id: session.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func otherSessionRow(session: Session) -> some View {
        SessionRowView(
            title: sessionList.titleForSession(session),
            subtitle: sessionList.subtitleForSession(session),
            source: session.source,
            isActive: session.id == currentSessionID,
            isOwned: false,
            isPinned: session.isPinned,
            tags: session.tags,
            runState: session.displayRunState
        )
        .sessionListRowStyle(isActive: session.id == sessionList.activeSessionID)
        .contentShape(Rectangle())
        .onTapGesture {
            sessionList.selectSession(id: session.id)
        }
        .contextMenu {
            Button {
                sessionList.togglePinned(id: session.id)
            } label: {
                Label(session.isPinned ? "Unpin Session" : "Pin Session",
                      systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            exportMarkdownButton(session: session)
        }
    }

    // MARK: - Section Header

    private func sessionSection<Content: View>(
        title: String,
        icon: String,
        count: Int,
        isCollapsed: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Section {
            if !isCollapsed {
                content()
            }
        } header: {
            collapsibleHeader(
                title: title,
                icon: icon,
                count: count,
                isCollapsed: isCollapsed
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onToggle()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(Theme.background)
        }
    }

    // MARK: - Helpers


    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions")
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiary)

            HStack(spacing: 8) {
                // Always a plain button — the gateway switcher is the single
                // place to choose a backend; onCreateSession targets the
                // focused one. The per-backend dropdown this replaced
                // duplicated the switcher.
                sidebarHeaderButton(
                    icon: "plus",
                    title: "New Session",
                    accessibilityLabel: "New Session",
                    accessibilityID: "newSessionButton",
                    isPrimary: true,
                    action: { onCreateSession?() }
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
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.22) : Color.clear)
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
    var isPinned: Bool = false
    var tags: [String] = []
    var runState: SessionRunState = .idle

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
                .frame(width: 24)
                .accessibilityLabel(stateAccessibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                        .foregroundStyle(isArchived ? .secondary : .primary)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("Pinned")
                    }
                }

                HStack(spacing: 5) {
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                }
            }

            Spacer()

            trailingBadge
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var stateAccessibilityLabel: String {
        switch runState {
        case .queued: return "Queued"
        case .streaming: return "Streaming"
        case .toolRunning: return "Tool running"
        case .waitingForUser: return "Waiting for user"
        case .idle: return "Idle"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch runState {
        case .queued:
            Image(systemName: "clock")
                .font(.body)
                .foregroundStyle(.secondary)
        case .streaming:
            PulsingDot(color: Theme.success)
        case .toolRunning:
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.body)
                .foregroundStyle(Theme.accent)
        case .waitingForUser:
            Image(systemName: "pause.circle.fill")
                .font(.body)
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "circle")
                .font(.body)
                .foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.red)
        case .canceled:
            Image(systemName: "slash.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if isActive {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.accent)
        } else if isArchived {
            Image(systemName: "archivebox")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        } else if !isOwned {
            Image(systemName: observerIconName)
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }

    private var observerIconName: String {
        switch source?.lowercased() {
        case "telegram": return "paperplane"
        case "discord": return "headphones"
        case "cli", "tui": return "terminal"
        case "cron": return "clock"
        default: return "eye"
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
    SessionListView(currentSessionID: nil)
        .environmentObject(SessionListViewModel())
        .environmentObject(SettingsViewModel())
        .frame(width: 280, height: 500)
}
