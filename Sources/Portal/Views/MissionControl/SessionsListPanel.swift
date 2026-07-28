#if os(macOS)
import SwiftUI

/// Flat sorted session list driven entirely by the shared `SessionsFilterState`.
/// No section headers — filters narrow the list, the global sort controls order.
@MainActor
internal struct SessionsListPanel: View {
    @EnvironmentObject private var sessionList: SessionListViewModel
    @EnvironmentObject private var filterState: SessionsFilterState

    internal var onOpenSession: ((String) -> Void)?

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
        return filterState.sorted(result)
    }

    private var liveCount: Int { filteredSessions.filter { $0.isLive }.count }

    // Max duration among visible sessions — used to scale the inline duration bar.
    private var maxDuration: TimeInterval {
        filteredSessions.compactMap { durationOf($0) }.max() ?? 1
    }

    internal var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider().overlay(Theme.border.opacity(0.5))
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Summary bar

    private var summaryBar: some View {
        HStack(spacing: 14) {
            statChip("\(filteredSessions.count)", label: "Showing", color: Theme.accent)
            statChip("\(liveCount)", label: "Live", color: Theme.success)
            statChip("\(filteredSessions.count - liveCount)", label: "Ended", color: Theme.secondary)
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Theme.success).frame(width: 5, height: 5)
                Text("Auto-refresh").font(.caption2).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.6))
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if filteredSessions.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredSessions) { sessionCard($0) }
                }
            }
            .padding(10)
        }
    }

    // MARK: - Card

    private func sessionCard(_ session: Session) -> some View {
        let runState = session.displayRunState
        let title = sessionList.titleForSession(session)
        let isLive = session.isLive
        let isSelected = filterState.selectedSessionID == session.id
        let sourceColor = colorForSource(session.displaySource)

        return Button {
            filterState.selectedSessionID = session.id
            onOpenSession?(session.id)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Source color strip
                    RoundedRectangle(cornerRadius: 2)
                        .fill(sourceColor.opacity(0.7))
                        .frame(width: 3)
                        .padding(.vertical, 6)

                    // Run state icon
                    runStateIcon(runState, isLive: isLive)
                        .frame(width: 26, height: 26)
                        .background(runStateColor(runState, isLive: isLive).opacity(0.1))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        // Title row
                        HStack(spacing: 5) {
                            Text(title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                            if isLive {
                                runStateLabel(runState)
                            }
                            Spacer(minLength: 0)
                            if let la = session.lastActive {
                                Text(la.relativeString)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }

                        // Subtitle row
                        HStack(spacing: 6) {
                            if let src = session.source {
                                Text(src).font(.caption2).foregroundStyle(Theme.tertiary)
                            }
                            if session.messageCount > 0 {
                                messageDots(session.messageCount)
                            }
                            Spacer(minLength: 0)
                            if let dur = durationOf(session) {
                                Text(formatDuration(dur))
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }

                        // Duration bar
                        if let dur = durationOf(session), maxDuration > 0 {
                            durationBar(dur, max: maxDuration, isLive: isLive)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 10)
            }
            .background(isSelected ? Theme.accent.opacity(0.08) : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Theme.accent.opacity(0.45)
                        : isLive ? runStateColor(runState, isLive: true).opacity(0.25) : Color.clear,
                        lineWidth: 1
                    )
            )
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

    // MARK: - Mini-visualizations

    /// Thin proportional bar showing how long this session ran relative to the longest visible session.
    private func durationBar(_ duration: TimeInterval, max maxDur: TimeInterval, isLive: Bool) -> some View {
        let ratio = min(1, duration / maxDur)
        let color = isLive ? Theme.success : Theme.accent
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border.opacity(0.25)).frame(height: 3)
                Capsule().fill(color.opacity(0.55))
                    .frame(width: geo.size.width * ratio, height: 3)
            }
        }
        .frame(height: 3)
        .padding(.top, 4)
    }

    /// Message count rendered as stacked dots — gives a visual density sense without a number.
    private func messageDots(_ count: Int) -> some View {
        let capped = min(count, 20)
        let filled = min(capped, count)
        return HStack(spacing: 2) {
            ForEach(0..<filled, id: \.self) { _ in
                Circle().fill(Theme.accent.opacity(0.4)).frame(width: 4, height: 4)
            }
        }
    }

    // MARK: - Helpers

    private func durationOf(_ s: Session) -> TimeInterval? {
        guard let start = s.startedAt else { return nil }
        let end = s.endedAt ?? s.lastActive ?? Date()
        let t = end.timeIntervalSince(start)
        return t > 0 ? t : nil
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t))s" }
        if t < 3_600 { return "\(Int(t / 60))m" }
        let h = Int(t / 3_600)
        let m = Int(t.truncatingRemainder(dividingBy: 3_600) / 60)
        return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }

    private func colorForSource(_ source: String) -> Color {
        switch source.lowercased() {
        case "native", "hermes native": return Theme.accent
        case "telegram": return .blue
        case "discord":  return .purple
        case "cli", "tui": return .orange
        case "web":      return .teal
        default:         return Theme.tertiary
        }
    }

    private func runStateColor(_ state: SessionRunState, isLive: Bool) -> Color {
        guard isLive else { return Theme.tertiary }
        switch state {
        case .queued:         return .secondary
        case .streaming, .idle: return Theme.success
        case .toolRunning:    return Theme.accent
        case .waitingForUser: return .orange
        case .failed:         return .red
        case .canceled:       return .secondary
        }
    }

    @ViewBuilder
    private func runStateIcon(_ state: SessionRunState, isLive: Bool) -> some View {
        if isLive {
            switch state {
            case .queued:          Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
            case .streaming, .idle: PulsingDot(color: Theme.success).frame(width: 9, height: 9)
            case .toolRunning:     Image(systemName: "wrench.and.screwdriver.fill").font(.caption).foregroundStyle(Theme.accent)
            case .waitingForUser:  Image(systemName: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
            case .failed:          Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            case .canceled:        Image(systemName: "slash.circle").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "circle").font(.caption).foregroundStyle(Theme.tertiary)
        }
    }

    private func runStateLabel(_ state: SessionRunState) -> some View {
        let label = state == .idle ? "Active" : state.displayName
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.success)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.success.opacity(0.12), in: Capsule())
    }

    private func statChip(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.subheadline.monospacedDigit().bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(Theme.tertiary)
        }
        .frame(minWidth: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(Theme.tertiary)
            Text("No sessions").font(.subheadline).foregroundStyle(Theme.secondary)
            Text("Adjust the filters or wait for a session to start.")
                .font(.caption).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
#endif
