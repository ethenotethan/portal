#if os(macOS)
import Charts
import SwiftUI

/// Dual-layer sessions timeline.
///
/// **Top strip** — frequency area+line: sessions active per bucket.
/// **Bottom** — flamechart: span bars with greedy lane packing, "now" cursor,
/// hover tooltip, click to select. X-axis labels always visible via explicit
/// plot insets.
@MainActor
internal struct SessionsTimelinePlot: View {
    @EnvironmentObject private var filterState: SessionsFilterState
    @EnvironmentObject private var sessionList: SessionListViewModel

    internal var onSelect: ((String) -> Void)?

    @State private var now = Date()
    @State private var hoveredID: String?
    @State private var tooltipSpan: Span?
    @State private var tooltipLocation: CGPoint = .zero

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    // MARK: - Data model

    internal struct Span: Identifiable {
        internal let id: String
        internal let title: String
        internal let start: Date
        internal let end: Date
        internal let isLive: Bool
        internal let lane: String
        internal let source: String
    }

    private struct FreqPoint: Identifiable {
        let id: Int
        let date: Date
        let count: Int
    }

    // MARK: - Derived data

    private var spans: [Span] {
        let raw = filterState
            .filteredSessions(from: sessionList.sessions.filter { !$0.isArchived })
            .compactMap { s -> (Session, Date, Date)? in
                guard let start = s.startedAt else { return nil }
                let end: Date
                if s.isLive {
                    end = now
                } else if let e = s.endedAt ?? s.lastActive {
                    end = e
                } else {
                    // No end-time info at all — show as a minimal 1-min bar at start
                    // so the session is visible on the timeline rather than invisible.
                    end = start.addingTimeInterval(60)
                }
                // Ensure minimum visible width (1 sec) — degenerate spans are invisible.
                let clampedEnd = max(end, start.addingTimeInterval(1))
                return (s, start, clampedEnd)
            }
            .sorted { $0.1 < $1.1 }

        var laneEnds: [Date] = []
        return raw.map { (s, start, end) in
            let laneIdx: Int
            if let idx = laneEnds.firstIndex(where: { $0 <= start }) {
                laneIdx = idx; laneEnds[idx] = end
            } else {
                laneIdx = laneEnds.count; laneEnds.append(end)
            }
            return Span(
                id: s.id,
                title: sessionList.titleForSession(s),
                start: start, end: end,
                isLive: s.isLive,
                lane: "\(laneIdx)",
                source: s.displaySource
            )
        }
    }

    private var timeDomain: (Date, Date) {
        guard !spans.isEmpty,
              let lo = spans.map(\.start).min(),
              let hi = spans.map(\.end).max() else {
            return (now.addingTimeInterval(-3_600), now)
        }
        let pad = max(60, hi.timeIntervalSince(lo) * 0.04)
        return (lo.addingTimeInterval(-pad), hi.addingTimeInterval(pad))
    }

    private var freqPoints: [FreqPoint] {
        guard !spans.isEmpty else { return [] }
        let (lo, hi) = timeDomain
        let totalSpan = hi.timeIntervalSince(lo)
        let bucketCount = 60
        let bucketSize = totalSpan / Double(bucketCount)
        return (0..<bucketCount).map { i in
            let bStart = lo.addingTimeInterval(Double(i) * bucketSize)
            let bEnd   = bStart.addingTimeInterval(bucketSize)
            let count  = spans.filter { $0.start < bEnd && $0.end > bStart }.count
            let mid    = lo.addingTimeInterval((Double(i) + 0.5) * bucketSize)
            return FreqPoint(id: i, date: mid, count: count)
        }
    }

    // MARK: - Body

    internal var body: some View {
        if spans.isEmpty {
            PanelEmptyState(icon: "clock", message: "No sessions with timing data")
        } else {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    frequencyLayer.frame(height: 56)
                    Divider().overlay(Theme.border.opacity(0.2))
                    flameLayer
                }
                if let span = tooltipSpan {
                    tooltip(span)
                        .position(x: tooltipLocation.x, y: tooltipLocation.y - 36)
                        .allowsHitTesting(false)
                }
            }
            .onReceive(timer) { now = $0 }
        }
    }

    // MARK: - Frequency strip

    private var frequencyLayer: some View {
        let (lo, hi) = timeDomain
        return Chart(freqPoints) { pt in
            AreaMark(x: .value("Time", pt.date), y: .value("Active", pt.count))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Time", pt.date), y: .value("Active", pt.count))
                .foregroundStyle(Theme.accent.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
        }
        .chartXScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { v in
                AxisValueLabel()
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .chartPlotStyle { $0.background(Color.clear) }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Flamechart

    private var flameLayer: some View {
        let (lo, hi) = timeDomain
        let spanSec = hi.timeIntervalSince(lo)
        let fmt: Date.FormatStyle = {
            if spanSec < 3_600 { return .dateTime.hour().minute().second() }
            if spanSec < 86_400 { return .dateTime.hour().minute() }
            return .dateTime.month().day().hour().minute()
        }()
        return Chart(spans) { span in
            BarMark(
                xStart: .value("Start", span.start),
                xEnd: .value("End", span.end),
                y: .value("Lane", span.lane)
            )
            .foregroundStyle(spanColor(span))
            .cornerRadius(2)
            .opacity(hoveredID == nil || hoveredID == span.id ? 1.0 : 0.28)

            // "Now" rule line
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Theme.success.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("now")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.success)
                }
        }
        .chartXScale(domain: lo...hi)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.3))
                AxisTick(length: 4).foregroundStyle(Theme.border)
                AxisValueLabel(format: fmt)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondary)
            }
        }
        // Reserve space below the plot for axis labels — without this they're clipped
        .chartPlotStyle { plot in
            plot.padding(.bottom, 2)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let hit = hitSpan(proxy: proxy, geo: geo, at: loc)
                            hoveredID = hit?.id
                            tooltipSpan = hit
                            tooltipLocation = loc
                        case .ended:
                            hoveredID = nil
                            tooltipSpan = nil
                        }
                    }
                    .onTapGesture { loc in
                        if let span = hitSpan(proxy: proxy, geo: geo, at: loc) {
                            onSelect?(span.id)
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    // MARK: - Tooltip

    private func tooltip(_ span: Span) -> some View {
        let dur = span.end.timeIntervalSince(span.start)
        return VStack(alignment: .leading, spacing: 3) {
            Text(span.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(span.source).font(.caption2).foregroundStyle(Theme.tertiary)
                Text(formatDuration(dur)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.tertiary)
                if span.isLive {
                    Text("LIVE").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.success)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .fixedSize()
    }

    // MARK: - Helpers

    private func spanColor(_ span: Span) -> Color {
        if span.isLive { return Theme.success.opacity(0.75) }
        if hoveredID == span.id { return Theme.accent.opacity(0.9) }
        return sourceColor(span.source).opacity(0.55)
    }

    private func sourceColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "native", "hermes native": return Theme.accent
        case "telegram": return .blue
        case "discord":  return .purple
        case "cli", "tui": return .orange
        case "web":      return .teal
        default:         return Theme.accent
        }
    }

    private func hitSpan(proxy: ChartProxy, geo: GeometryProxy, at loc: CGPoint) -> Span? {
        let origin = geo.frame(in: .local).origin
        let pt = CGPoint(x: loc.x - origin.x, y: loc.y - origin.y)
        guard let date: Date = proxy.value(atX: pt.x),
              let lane: String = proxy.value(atY: pt.y)
        else { return nil }
        return spans.first { s in s.lane == lane && date >= s.start && date <= s.end }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t))s" }
        if t < 3_600 { return "\(Int(t / 60))m" }
        let h = Int(t / 3_600)
        let m = Int(t.truncatingRemainder(dividingBy: 3_600) / 60)
        return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }
}
#endif
