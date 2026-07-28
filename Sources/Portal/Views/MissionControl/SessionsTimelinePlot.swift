#if os(macOS)
import SwiftUI
import Charts

/// Horizontal Gantt-style time plot of all sessions. Each session is a bar from
/// `startedAt` to `endedAt ?? now`, grouped into horizontal lanes by source.
/// Live sessions have a pulsing trailing edge; clicking a bar fires `onSelect`.
internal struct SessionsTimelinePlot: View {
    internal let sessions: [Session]
    internal let titles: (Session) -> String
    internal var onSelect: ((String) -> Void)?

    @State private var now = Date()
    @State private var hoveredID: String?

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private struct Bar: Identifiable {
        let id: String
        let title: String
        let lane: String
        let start: Date
        let end: Date
        let isLive: Bool
    }

    private var bars: [Bar] {
        sessions.compactMap { s -> Bar? in
            guard let start = s.startedAt else { return nil }
            let end = s.isLive ? now : (s.endedAt ?? s.lastActive ?? now)
            guard end > start else { return nil }
            return Bar(
                id: s.id,
                title: titles(s),
                lane: s.displaySource,
                start: start,
                end: end,
                isLive: s.isLive
            )
        }
    }

    private var lanes: [String] {
        var seen = Set<String>()
        return bars.compactMap { seen.insert($0.lane).inserted ? $0.lane : nil }
    }

    private var domain: (Date, Date) {
        let starts = bars.map(\.start)
        let ends   = bars.map(\.end)
        guard let lo = starts.min(), let hi = ends.max() else { return (now, now) }
        let pad = max(60, hi.timeIntervalSince(lo) * 0.04)
        return (lo.addingTimeInterval(-pad), hi.addingTimeInterval(pad))
    }

    internal var body: some View {
        if bars.isEmpty {
            PanelEmptyState(icon: "clock", message: "No sessions with timing data")
        } else {
            chart
                .onReceive(timer) { now = $0 }
        }
    }

    private var chart: some View {
        Chart(bars) { bar in
            BarMark(
                xStart: .value("Start", bar.start),
                xEnd: .value("End", bar.end),
                y: .value("Source", bar.lane)
            )
            .foregroundStyle(barColor(bar))
            .cornerRadius(3)
            .opacity(hoveredID == nil || hoveredID == bar.id ? 1 : 0.45)
        }
        .chartXScale(domain: domain.0...domain.1)
        .chartYAxis {
            AxisMarks(preset: .aligned) { value in
                AxisValueLabel {
                    if let lane = value.as(String.self) {
                        Text(lane)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let date: Date = proxy.value(atX: loc.x - geo.frame(in: .local).minX),
                                  let lane: String = proxy.value(atY: loc.y - geo.frame(in: .local).minY)
                            else { hoveredID = nil; return }
                            hoveredID = bars.first { b in
                                b.lane == lane && date >= b.start && date <= b.end
                            }?.id
                        case .ended:
                            hoveredID = nil
                        }
                    }
                    .onTapGesture { loc in
                        guard let date: Date = proxy.value(atX: loc.x - geo.frame(in: .local).minX),
                              let lane: String = proxy.value(atY: loc.y - geo.frame(in: .local).minY),
                              let bar = bars.first(where: { b in
                                  b.lane == lane && date >= b.start && date <= b.end
                              })
                        else { return }
                        onSelect?(bar.id)
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func barColor(_ bar: Bar) -> Color {
        if bar.isLive { return Theme.success.opacity(0.8) }
        if hoveredID == bar.id { return Theme.accent.opacity(0.7) }
        return Theme.accent.opacity(0.45)
    }
}
#endif
