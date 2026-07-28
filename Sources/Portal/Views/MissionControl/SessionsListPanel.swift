#if os(macOS)
import SwiftUI

/// The sessions card list as a canvas panel. Unlike `SessionsDashboard` (used
/// in the iOS sheet), this view reads from the shared `SessionsFilterState` so
/// search and filter changes made in the search panel are reflected here
/// immediately — and vice versa.
@MainActor
internal struct SessionsListPanel: View {
    @EnvironmentObject private var sessionList: SessionListViewModel
    @EnvironmentObject private var filterState: SessionsFilterState

    internal var onOpenSession: ((String) -> Void)?

    @State private var displayMode: DisplayMode = .status

    private enum DisplayMode: String, CaseIterable {
        case status = "By Status"
        case source = "By Source"
    }

    private var allSessions: [Session] { sessionList.sessions.filter { !$0.isArchived } }

    private var filteredSessions: [Session] {
        var result = filterState.filteredSessions(from: allSessions)
        if !filterState.searchText.isEmpty {
            let q = filterState.searchText.lowercased()
            result = result.filter { s in
                sessionList.titleForSession(s).lowercased().contains(q)
                    || (s.preview ?? "").lowercased().contains(q)
                    || (s.source ?? "").lowercased().contains(q)
                    || s.id.lowercased().contains(q)
            }
        }
        return result
    }

    private var liveSessions: [Session] {
        filteredSessions.filter { $0.isLive }
            .sorted { $0.lastActive ?? .distantPast > $1.lastActive ?? .distantPast }
    }

    private var endedSessions: [Session] {
        filteredSessions.filter { !$0.isLive }
            .sorted { $0.lastActive ?? .distantPast > $1.lastActive ?? .distantPast }
    }

    private var groupedBySource: [(source: String, sessions: [Session])] {
        let groups = Dictionary(grouping: filteredSessions) { $0.displaySource }
        return groups.sorted { $0.key < $1.key }.map { (source: $0.key, sessions: $0.value
            .sorted { $0.lastActive ?? .distantPast > $1.lastActive ?? .distantPast }
        )}
    }

    private var totalCount: Int { filteredSessions.count }
    private var liveCount: Int { filteredSessions.filter { $0.isLive }.count }

    internal var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider().overlay(Theme.border.opacity(0.5))
            modePicker
            Divider().overlay(Theme.border.opacity(0.5))
            sessionList_
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Sub-views

    private var summaryBar: some View {
        HStack(spacing: 14) {
            chip("\(totalCount)", label: "Showing", color: Theme.accent)
            chip("\(liveCount)",  label: "Live",    color: Theme.success)
            chip("\(totalCount - liveCount)", label: "Ended", color: Theme.secondary)
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Theme.success).frame(width: 5, height: 5)
                Text("Auto-refresh")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.6))
    }

    private var modePicker: some View {
        Picker("", selection: $displayMode) {
            ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sessionList_: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                switch displayMode {
                case .status:  statusSections
                case .source:  sourceSections
                }
                if filteredSessions.isEmpty && !allSessions.isEmpty { noResults }
                else if allSessions.isEmpty { emptyState }
            }
            .padding(12)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSections: some View {
        if !liveSessions.isEmpty {
            sectionHeader("Live", count: liveSessions.count, icon: "bolt.fill", color: Theme.success)
            ForEach(liveSessions) { sessionCard($0) }
        }
        if !endedSessions.isEmpty {
            sectionHeader("Ended", count: endedSessions.count, icon: "moon.zzz.fill", color: Theme.secondary)
            ForEach(endedSessions) { sessionCard($0) }
        }
    }

    @ViewBuilder
    private var sourceSections: some View {
        ForEach(groupedBySource, id: \.source) { group in
            let live = group.sessions.filter { $0.isLive }
            sectionHeader(group.source, count: group.sessions.count,
                          icon: sourceIcon(group.source),
                          color: live.isEmpty ? Theme.secondary : Theme.success,
                          activeCount: live.count)
            ForEach(group.sessions) { sessionCard($0) }
        }
    }

    // MARK: - Card

    private func sessionCard(_ session: Session) -> some View {
        let runState = session.displayRunState
        let title    = sessionList.titleForSession(session)
        let live     = session.isLive

        return Button { onOpenSession?(session.id) } label: {
            HStack(spacing: 12) {
                runStateIcon(runState, isLive: live)
                    .frame(width: 30, height: 30)
                    .background(runStateColor(runState, isLive: live).opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if !session.isOwned, let src = session.source {
                            Text(src.uppercased())
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if let sub = subtitle(session) {
                            Text(sub).font(.caption2).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        if let la = session.lastActive {
                            Text(la.relativeString).font(.caption2).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                Spacer()
                if live { runStateLabel(runState, isLive: true) }
            }
            .padding(10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(live ? runStateColor(runState, isLive: true).opacity(0.3) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.isOwned {
                Button { sessionList.selectSession(id: session.id) } label: {
                    Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Button { onOpenSession?(session.id) } label: {
                Label("Mission Control", systemImage: "network")
            }
            Divider()
            if session.isPinned {
                Button { sessionList.togglePinned(id: session.id) } label: { Label("Unpin", systemImage: "pin.slash") }
            } else {
                Button { sessionList.togglePinned(id: session.id) } label: { Label("Pin", systemImage: "pin") }
            }
        }
    }

    // MARK: - Reusable pieces

    private func chip(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.subheadline.monospacedDigit().bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(Theme.tertiary)
        }
        .frame(minWidth: 44)
    }

    private func sectionHeader(_ title: String, count: Int, icon: String, color: Color, activeCount: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(title).font(.subheadline.bold()).foregroundStyle(Theme.primary)
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.15), in: Capsule())
            if let ac = activeCount, ac > 0 {
                Text("\(ac) live").font(.caption2.weight(.medium)).foregroundStyle(Theme.success)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.success.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func runStateIcon(_ state: SessionRunState, isLive: Bool) -> some View {
        if isLive {
            switch state {
            case .queued:        Image(systemName: "clock").font(.callout).foregroundStyle(.secondary)
            case .streaming, .idle: PulsingDot(color: Theme.success).frame(width: 10, height: 10)
            case .toolRunning:   Image(systemName: "wrench.and.screwdriver.fill").font(.callout).foregroundStyle(Theme.accent)
            case .waitingForUser: Image(systemName: "pause.circle.fill").font(.callout).foregroundStyle(.orange)
            case .failed:        Image(systemName: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
            case .canceled:      Image(systemName: "slash.circle").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "circle").font(.callout).foregroundStyle(Theme.tertiary)
        }
    }

    private func runStateColor(_ state: SessionRunState, isLive: Bool) -> Color {
        guard isLive else { return Theme.tertiary }
        switch state {
        case .queued:        return .secondary
        case .streaming, .idle: return Theme.success
        case .toolRunning:   return Theme.accent
        case .waitingForUser: return .orange
        case .failed:        return .red
        case .canceled:      return .secondary
        }
    }

    @ViewBuilder
    private func runStateLabel(_ state: SessionRunState, isLive: Bool) -> some View {
        let label = isLive ? (state == .idle ? "Active" : state.displayName) : "Ended"
        let color = runStateColor(state, isLive: isLive)
        Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
    }

    private func subtitle(_ session: Session) -> String? {
        var parts: [String] = []
        if session.isOwned { parts.append("Native") }
        else if let src = session.source { parts.append(src) }
        if session.messageCount > 0 { parts.append("\(session.messageCount) msgs") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "native", "hermes native": return "macbook.and.iphone"
        case "telegram": return "paperplane"
        case "discord":  return "headphones"
        case "cli", "tui": return "terminal"
        case "cron":     return "clock"
        case "web":      return "globe"
        default:         return "questionmark.circle"
        }
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.tertiary)
            Text("Adventure awaits 🚀").font(.subheadline).foregroundStyle(Theme.secondary)
            Text("Start a new chat to begin exploring.").font(.caption).foregroundStyle(Theme.tertiary)
        }
        .padding(40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(Theme.tertiary)
            Text("No sessions found").font(.subheadline).foregroundStyle(Theme.secondary)
            Text("Sessions from all connected relays will appear here.")
                .font(.caption).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
#endif
