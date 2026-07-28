#if os(macOS)
import Charts
import SwiftUI

/// Categorical breakdown of sessions by source — a donut chart on top with a
/// sorted legend list below. Both respond to `SessionsFilterState`.
@MainActor
internal struct SessionsSourceBreakdown: View {
    @EnvironmentObject private var filterState: SessionsFilterState
    @EnvironmentObject private var sessionList: SessionListViewModel

    private struct Slice: Identifiable {
        let id: String
        let source: String
        let count: Int
        let color: Color
    }

    private var slices: [Slice] {
        let sessions = filterState.filteredSessions(from: sessionList.sessions.filter { !$0.isArchived })
        let groups = Dictionary(grouping: sessions) { $0.displaySource }
        let sorted = groups.sorted { $0.value.count > $1.value.count }
        let palette: [Color] = [
            Theme.accent, Theme.success, .orange, .purple, .pink, .teal, .indigo, .yellow
        ]
        return sorted.enumerated().map { idx, pair in
            Slice(
                id: pair.key,
                source: pair.key,
                count: pair.value.count,
                color: palette[idx % palette.count]
            )
        }
    }

    private var total: Int { slices.reduce(0) { $0 + $1.count } }

    internal var body: some View {
        if slices.isEmpty {
            PanelEmptyState(icon: "chart.pie", message: "No sessions to break down")
        } else {
            VStack(spacing: 0) {
                donut
                    .frame(height: 160)
                    .padding(.top, 8)
                Divider().overlay(Theme.border.opacity(0.4))
                legend
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
        }
    }

    // MARK: - Donut chart

    private var donut: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Count", slice.count),
                innerRadius: .ratio(0.56),
                angularInset: 1.5
            )
            .foregroundStyle(slice.color)
            .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 2) {
                Text("\(total)")
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                Text("sessions")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Legend

    private var legend: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)
                        Text(slice.source)
                            .font(.caption)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(slice.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                        Text(total > 0 ? String(format: "%.0f%%", Double(slice.count) / Double(total) * 100) : "—")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Theme.surface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if filterState.filterSource == slice.source {
                                filterState.filterSource = nil
                            } else {
                                filterState.filterSource = slice.source
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(filterState.filterSource == slice.source ? slice.color.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
            }
            .padding(10)
        }
    }
}
#endif
