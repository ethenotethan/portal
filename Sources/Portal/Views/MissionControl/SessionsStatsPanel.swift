#if os(macOS)
import SwiftUI

/// 2×3 grid of aggregate stat tiles — always shows numbers for the current
/// `SessionsFilterState` window so the tiles respond to every filter.
@MainActor
internal struct SessionsStatsPanel: View {
    @EnvironmentObject private var filterState: SessionsFilterState
    @EnvironmentObject private var sessionList: SessionListViewModel

    private var filtered: [Session] {
        filterState.filteredSessions(from: sessionList.sessions.filter { !$0.isArchived })
    }

    // MARK: - Computed stats

    private var liveCount: Int { filtered.filter { $0.isLive }.count }
    private var endedCount: Int { filtered.filter { !$0.isLive }.count }
    private var totalMessages: Int { filtered.reduce(0) { $0 + $1.messageCount } }

    private var avgDuration: TimeInterval {
        let ended = filtered.filter { $0.endedAt != nil || $0.lastActive != nil }
        guard !ended.isEmpty else { return 0 }
        let total = ended.reduce(0.0) { acc, s -> Double in
            guard let start = s.startedAt else { return acc }
            let end = s.endedAt ?? s.lastActive ?? Date()
            return acc + end.timeIntervalSince(start)
        }
        return total / Double(ended.count)
    }

    private var todayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return filtered.filter { ($0.startedAt ?? .distantPast) >= startOfDay }.count
    }

    private var errorRate: Double {
        guard !filtered.isEmpty else { return 0 }
        let failed = filtered.filter { $0.displayRunState == .failed }.count
        return Double(failed) / Double(filtered.count) * 100
    }

    // MARK: - View

    internal var body: some View {
        let tiles: [StatTile] = [
            StatTile(value: "\(filtered.count)", label: "Total", icon: "list.bullet.rectangle", color: Theme.accent),
            StatTile(value: "\(liveCount)", label: "Live", icon: "bolt.fill", color: Theme.success),
            StatTile(value: "\(todayCount)", label: "Today", icon: "calendar", color: Theme.accent),
            StatTile(value: "\(endedCount)", label: "Ended", icon: "moon.zzz.fill", color: Theme.secondary),
            StatTile(value: totalMessages.abbreviatedString, label: "Messages", icon: "bubble.left.and.bubble.right", color: Theme.accent),
            StatTile(value: formatDuration(avgDuration), label: "Avg duration", icon: "timer", color: Theme.tertiary),
        ]

        GeometryReader { geo in
            let cols = geo.size.width < 260 ? 1 : 2
            let colWidth = (geo.size.width - 12 * 2 - (cols == 2 ? 8.0 : 0)) / CGFloat(cols)
            ScrollView {
                VStack(spacing: 8) {
                    let rows = stride(from: 0, to: tiles.count, by: cols).map {
                        Array(tiles[$0..<min($0 + cols, tiles.count)])
                    }
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(spacing: 8) {
                            ForEach(row) { tile in
                                tileView(tile)
                                    .frame(width: colWidth)
                            }
                            if row.count < cols {
                                Spacer()
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background)
    }

    private func tileView(_ tile: StatTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: tile.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tile.color)
                Text(tile.label)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            Text(tile.value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private struct StatTile: Identifiable {
        let id = UUID()
        let value: String
        let label: String
        let icon: String
        let color: Color
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "—" }
        if t < 60 { return "\(Int(t))s" }
        if t < 3_600 { return "\(Int(t / 60))m" }
        let h = Int(t / 3_600)
        let m = Int((t.truncatingRemainder(dividingBy: 3_600)) / 60)
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}

private extension Int {
    var abbreviatedString: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        return "\(self)"
    }
}
#endif
