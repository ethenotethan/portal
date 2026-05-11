import SwiftUI
import Combine

struct SessionsDashboard: View {
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    var onOpenSession: ((String) -> Void)?

    @State private var refreshTimer: Timer?
    @State private var searchText = ""
    @State private var filterSource: String?
    @State private var filterStatus: StatusFilter = .all
    @State private var displayMode: DisplayMode = .status

    enum DisplayMode: String, CaseIterable {
        case status = "By Status"
        case source = "By Source"
    }

    enum StatusFilter: String, CaseIterable {
        case all = "All"
        case live = "Live"
        case ended = "Ended"
    }

    private var allSessions: [Session] {
        sessionList.sessions.filter { !$0.isArchived }
    }

    private var filteredSessions: [Session] {
        var result = allSessions

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { s in
                sessionList.titleForSession(s).lowercased().contains(q)
                    || (s.preview ?? "").lowercased().contains(q)
                    || (s.source ?? "").lowercased().contains(q)
                    || s.id.lowercased().contains(q)
            }
        }

        switch filterStatus {
        case .all: break
        case .live: result = result.filter { $0.isLive }
        case .ended: result = result.filter { !$0.isLive }
        }

        if let src = filterSource {
            result = result.filter { $0.displaySource == src }
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

    private var availableSources: [String] {
        let sources = Set(allSessions.map { $0.displaySource })
        return sources.sorted()
    }

    private var totalCount: Int { filteredSessions.count }
    private var liveCount: Int { filteredSessions.filter { $0.isLive }.count }
    private var unfilteredTotal: Int { allSessions.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider().background(Theme.border)
                ScrollView {
                    LazyVStack(spacing: 16) {
                        summaryBar

                        Picker("", selection: $displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 4)

                        switch displayMode {
                        case .status:
                            statusSections
                        case .source:
                            sourceSections
                        }

                        if filteredSessions.isEmpty && !allSessions.isEmpty {
                            noResults
                        } else if allSessions.isEmpty {
                            emptyState
                        }
                    }
                    .padding(20)
                }
            }
            .background(Theme.background)
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Search sessions...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sessionList.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { startPolling() }
            .onDisappear { stopPolling() }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    filterPill(
                        label: filter.rawValue,
                        count: filter == .all ? unfilteredTotal : (filter == .live ? allSessions.filter { $0.isLive }.count : allSessions.filter { !$0.isLive }.count),
                        isSelected: filterStatus == filter,
                        color: filter == .live ? Theme.success : Theme.accent
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            filterStatus = filter
                        }
                    }
                }

                if availableSources.count > 1 {
                    Menu {
                        Button("All Sources") {
                            withAnimation(.easeInOut(duration: 0.15)) { filterSource = nil }
                        }
                        ForEach(availableSources, id: \.self) { source in
                            Button(source) {
                                withAnimation(.easeInOut(duration: 0.15)) { filterSource = source }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.caption)
                            Text(filterSource ?? "Source")
                                .font(.caption.weight(.medium))
                            if filterSource != nil {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(filterSource != nil ? Theme.accent.opacity(0.15) : Theme.surface)
                        .foregroundStyle(filterSource != nil ? Theme.accent : Theme.secondary)
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterPill(label: String, count: Int, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? color : Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.15) : Theme.surface)
            .foregroundStyle(isSelected ? color : Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Sections

    @ViewBuilder
    private var statusSections: some View {
        if !liveSessions.isEmpty {
            sectionHeader("Live", count: liveSessions.count, icon: "bolt.fill", color: Theme.success)
            ForEach(liveSessions) { session in
                sessionCard(session)
            }
        }

        if !endedSessions.isEmpty {
            sectionHeader("Ended", count: endedSessions.count, icon: "moon.zzz.fill", color: Theme.secondary)
            ForEach(endedSessions) { session in
                sessionCard(session)
            }
        }
    }

    // MARK: - Source Sections

    @ViewBuilder
    private var sourceSections: some View {
        ForEach(groupedBySource, id: \.source) { group in
            let liveInGroup = group.sessions.filter { $0.isLive }
            let totalInGroup = group.sessions.count
            sectionHeader(
                group.source,
                count: totalInGroup,
                icon: sourceIcon(group.source),
                color: liveInGroup.isEmpty ? Theme.secondary : Theme.success,
                activeCount: liveInGroup.count
            )
            ForEach(group.sessions) { session in
                sessionCard(session)
            }
        }
    }

    // MARK: - Summary

    private var summaryBar: some View {
        HStack(spacing: 16) {
            summaryChip(value: "\(totalCount)", label: "Showing", color: Theme.accent)
            summaryChip(value: "\(liveCount)", label: "Live", color: Theme.success)
            summaryChip(value: "\(totalCount - liveCount)", label: "Ended", color: Theme.secondary)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 6, height: 6)
                Text("Auto-refresh")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryChip(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(minWidth: 56)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int, icon: String, color: Color, activeCount: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(Theme.primary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())

            if let activeCount, activeCount > 0 {
                Text("\(activeCount) live")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.success.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Card

    private func sessionCard(_ session: Session) -> some View {
        let runState = session.displayRunState
        let title = sessionList.titleForSession(session)
        let isLive = session.isLive

        return Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                onOpenSession?(session.id)
            }
        } label: {
            HStack(spacing: 12) {
                runStateIcon(runState, isLive: isLive)
                    .frame(width: 32, height: 32)
                    .background(runStateColor(runState, isLive: isLive).opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)

                        if !session.isOwned, let source = session.source {
                            Text(source.uppercased())
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        if let subtitle = sessionSubtitle(session), !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                        }

                        if let lastActive = session.lastActive {
                            Text(lastActive.relativeString)
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }

                Spacer()

                if isLive {
                    runStateLabel(runState, isLive: isLive)
                }
            }
            .padding(12)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isLive ? runStateColor(runState, isLive: isLive).opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.isOwned {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        sessionList.selectSession(id: session.id)
                    }
                } label: {
                    Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }

            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onOpenSession?(session.id)
                }
            } label: {
                Label("Mission Control", systemImage: "network")
            }

            if !session.isOwned {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onOpenSession?(session.id)
                    }
                } label: {
                    Label("Observe", systemImage: "eye")
                }
            }

            Divider()

            if session.isPinned {
                Button { sessionList.togglePinned(id: session.id) } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
            } else {
                Button { sessionList.togglePinned(id: session.id) } label: {
                    Label("Pin", systemImage: "pin")
                }
            }
        }
    }

    private func sessionSubtitle(_ session: Session) -> String? {
        var parts: [String] = []
        if session.isOwned {
            parts.append("Native")
        } else if let source = session.source {
            parts.append(source)
        }
        if session.messageCount > 0 {
            parts.append("\(session.messageCount) msgs")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Run State Views

    @ViewBuilder
    private func runStateIcon(_ state: SessionRunState, isLive: Bool) -> some View {
        if isLive {
            switch state {
            case .queued:
                Image(systemName: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .streaming, .idle:
                PulsingDot(color: Theme.success)
                    .frame(width: 10, height: 10)
            case .toolRunning:
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
            case .waitingForUser:
                Image(systemName: "pause.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .canceled:
                Image(systemName: "slash.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "circle")
                .font(.callout)
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func runStateColor(_ state: SessionRunState, isLive: Bool) -> Color {
        guard isLive else { return Theme.tertiary }
        switch state {
        case .queued: return .secondary
        case .streaming, .idle: return Theme.success
        case .toolRunning: return Theme.accent
        case .waitingForUser: return .orange
        case .failed: return .red
        case .canceled: return .secondary
        }
    }

    @ViewBuilder
    private func runStateLabel(_ state: SessionRunState, isLive: Bool) -> some View {
        let label: String = isLive ? (state == .idle ? "Active" : state.displayName) : "Ended"
        let color: Color = runStateColor(state, isLive: isLive)
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Source Helpers

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "native", "hermes native": return "macbook.and.iphone"
        case "telegram": return "paperplane"
        case "discord": return "headphones"
        case "cli", "tui": return "terminal"
        case "cron": return "clock"
        case "web": return "globe"
        default: return "questionmark.circle"
        }
    }

    // MARK: - Empty States

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiary)
            Text("No matching sessions")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text("Try a different search or filter.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiary)
            Text("No sessions found")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text("Sessions from all connected relays will appear here.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Polling

    private func startPolling() {
        Task { await sessionList.refreshSessions(refreshCron: false) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                await sessionList.refreshSessions(refreshCron: false)
            }
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Session Extensions

extension Session {
    var isLive: Bool {
        endedAt == nil
    }

    var displaySource: String {
        if isOwned { return "Native" }
        if let source, !source.isEmpty { return source.capitalized }
        return "Unknown"
    }
}

// MARK: - SessionRunState Extensions

extension SessionRunState {
    var isActive: Bool {
        switch self {
        case .streaming, .toolRunning, .queued, .waitingForUser: return true
        case .idle, .failed, .canceled: return false
        }
    }

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .streaming: return "Streaming"
        case .toolRunning: return "Tool"
        case .waitingForUser: return "Waiting"
        case .idle: return "Idle"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }
}

#Preview {
    SessionsDashboard()
        .environmentObject(SessionListViewModel())
        .environmentObject(GatewayClientWrapper())
}
