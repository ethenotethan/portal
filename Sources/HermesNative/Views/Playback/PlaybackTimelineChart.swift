import SwiftUI
import Charts

// MARK: - Timeline Lane

/// Horizontal lanes on the playback timeline chart, ordered top-to-bottom.
enum TimelineLane: String, CaseIterable, Plottable {
    case user      = "User"
    case assistant = "Assistant"
    case tool      = "Tool"
    case reasoning = "Reasoning"

    var displayName: String { rawValue }

    /// Default bar height fraction within the lane (0…1).
    var barHeightRatio: CGFloat {
        switch self {
        case .reasoning: return 0.4    // thin stripe
        case .user:      return 1.0    // points, not bars — included for completeness
        case .assistant: return 0.85
        case .tool:      return 0.85
        }
    }
}

// MARK: - Chart Datum

/// One renderable item on the playback timeline chart.
///
/// Each ``SessionTimelineEvent`` produces zero or one ``ChartDatum``:
/// - ``EventType/userMessage`` → point (no `endTime`)
/// - ``EventType/assistantMessage`` → bar spanning from its timestamp to the next event
/// - ``EventType/toolStart`` + ``EventType/toolEnd`` → single bar from start→end
/// - ``EventType/reasoningBlock`` → thin bar spanning to the next event
/// - ``EventType/turnBoundary`` → omitted from chart
struct ChartDatum: Identifiable {
    /// Maps to a ``SessionTimelineEvent/id`` (or `toolID` for tool-call pairs).
    let id: String
    let lane: TimelineLane
    let startTime: TimeInterval          // seconds relative to first event
    let endTime: TimeInterval?           // `nil` for point-only events
    let color: Color
    let eventType: EventType
    /// `true` when this tool call has no matching `.toolEnd` yet.
    let toolRunning: Bool
    let label: String?
}

// MARK: - PlaybackTimelineChart

/// A compact Gantt-style chart showing session events across four horizontal lanes.
///
/// - Lane 1 (top):  User messages — dots at message timestamps
/// - Lane 2:        Assistant messages — bar segments for message duration
/// - Lane 3:        Tool calls — coloured bars from start→end (amber = running, green = done)
/// - Lane 4 (bottom): Reasoning blocks — thin coloured bars
///
/// The chart scrolls horizontally when the timeline exceeds the visible width.
/// Tap a bar or dot to select the corresponding event (or deselect by tapping again).
struct PlaybackTimelineChart: View {
    // MARK: - Input

    /// All session events in chronological order.
    let events: [SessionTimelineEvent]

    /// Total wall-clock span of the session in seconds.
    let totalDuration: TimeInterval

    /// Bound to the currently-selected event ID.  Set to `nil` to deselect.
    @Binding var selectedEventID: String?

    // MARK: - Initializer

    /// Creates a new playback timeline chart.
    ///
    /// - Parameters:
    ///   - events: All session events (sorted chronologically by caller, but we sort again just in case).
    ///   - totalDuration: Session wall-clock duration in seconds.
    ///   - selectedEventID: Binding to the selected event identifier.
    init(
        events: [SessionTimelineEvent],
        totalDuration: TimeInterval,
        selectedEventID: Binding<String?>
    ) {
        self.events = events
        self.totalDuration = totalDuration
        self._selectedEventID = selectedEventID
    }

    // MARK: - Body

    public var body: some View {
        let chartData = computeChartData()

        if chartData.isEmpty {
            emptyState
        } else {
            scrollableChart(data: chartData)
        }
    }

    // MARK: - Scrollable Chart

    private func scrollableChart(data: [ChartDatum]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Chart(data) { datum in
                if let endTime = datum.endTime {
                    // ── Duration bar (assistant, tool, reasoning) ──
                    BarMark(
                        xStart: .value("Start", datum.startTime),
                        xEnd: .value("End", endTime),
                        y: .value("Lane", datum.lane)
                    )
                    .foregroundStyle(barColor(for: datum))
                    .cornerRadius(cornerRadius(for: datum.lane))
                } else {
                    // ── Point mark (user messages) ──
                    PointMark(
                        x: .value("Time", datum.startTime),
                        y: .value("Lane", datum.lane)
                    )
                    .foregroundStyle(datum.color)
                    .symbolSize(datum.id == selectedEventID ? 64 : 48)
                }
            }
            .chartXAxis { xAxis }
            .chartYAxis { yAxis }
            .chartPlotStyle { plot in
                plot.background(Theme.background)
            }
            .chartOverlay { proxy in
                tapOverlay(proxy: proxy, data: data)
            }
            .frame(width: chartWidth, height: 200)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiary)
            Text("No timeline events")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text("Playback events will appear as the session runs.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(30)
        .frame(height: 200)
    }

    // MARK: - Axis Styling

    @AxisContentBuilder
    private var xAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine()
                .foregroundStyle(Theme.border.opacity(0.2))
            AxisTick()
                .foregroundStyle(Theme.tertiary)
            AxisValueLabel {
                if let seconds = value.as(Double.self) {
                    Text(formatDuration(seconds))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    @AxisContentBuilder
    private var yAxis: some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisValueLabel {
                if let lane = value.as(TimelineLane.self) {
                    Text(lane.displayName)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    // MARK: - Tap Overlay (Selection)

    private func tapOverlay(proxy: ChartProxy, data: [ChartDatum]) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTap(at: location, proxy: proxy, data: data)
                }
        }
    }

    // MARK: - Selection Logic

    private func handleTap(at location: CGPoint, proxy: ChartProxy, data: [ChartDatum]) {
        guard let tappedTime: Double = proxy.value(atX: location.x) else {
            selectedEventID = nil
            return
        }

        // Prefer bars (duration events) whose span contains the tapped time.
        for datum in data where datum.endTime != nil {
            if tappedTime >= datum.startTime && tappedTime <= datum.endTime! {
                toggleSelection(datum.id)
                return
            }
        }

        // Fall back to nearest point event.
        var nearest: ChartDatum?
        var minDist = Double.infinity
        for datum in data where datum.endTime == nil {
            let dist = abs(datum.startTime - tappedTime)
            if dist < minDist {
                minDist = dist
                nearest = datum
            }
        }
        // Require reasonable proximity (2 seconds) for point taps.
        if let nearest = nearest, minDist <= 2.0 {
            toggleSelection(nearest.id)
        } else {
            selectedEventID = nil
        }
    }

    private func toggleSelection(_ id: String) {
        selectedEventID = (selectedEventID == id) ? nil : id
    }

    // MARK: - Colour Helpers

    /// Bar colour: boost opacity when selected, dim otherwise.
    private func barColor(for datum: ChartDatum) -> Color {
        datum.color.opacity(datum.id == selectedEventID ? 1.0 : 0.55)
    }

    /// Corner radius varies by lane.
    private func cornerRadius(for lane: TimelineLane) -> CGFloat {
        switch lane {
        case .reasoning: return 1
        case .user:      return 6
        default:         return 3
        }
    }

    // MARK: - Duration Formatting

    /// Formats a number of seconds into a compact label like `"12s"`, `"1m 30s"`, `"2m"`.
    private func formatDuration(_ total: TimeInterval) -> String {
        let seconds = abs(total)
        if seconds < 60 {
            return String(format: "%ds", Int(seconds.rounded()))
        }
        let mins = Int(seconds / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        if secs == 0 {
            return "\(mins)m"
        }
        return "\(mins)m \(secs)s"
    }

    // MARK: - Chart Width

    /// Scales the chart horizontally so that 1 second ≈ 50 pts, with a minimum.
    private var chartWidth: CGFloat {
        let pixelsPerSecond: CGFloat = 50
        return max(CGFloat(totalDuration) * pixelsPerSecond, 300)
    }

    // MARK: - Data Computation

    /// Transforms an array of ``SessionTimelineEvent`` into render-ready ``ChartDatum`` items.
    private func computeChartData() -> [ChartDatum] {
        guard !events.isEmpty else { return [] }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let firstTimestamp = sorted.first!.timestamp.timeIntervalSince1970

        var data: [ChartDatum] = []
        var openTools: [String: (start: TimeInterval, eventID: String, name: String?)] = [:]

        for (idx, event) in sorted.enumerated() {
            let relative = event.timestamp.timeIntervalSince1970 - firstTimestamp

            switch event.type {
            case .userMessage:
                data.append(ChartDatum(
                    id: event.id,
                    lane: .user,
                    startTime: relative,
                    endTime: nil,                       // point event
                    color: Color(hex: EventType.userMessage.colorHex) ?? .gray,
                    eventType: .userMessage,
                    toolRunning: false,
                    label: event.content
                ))

            case .assistantMessage:
                let end = endTime(forIndex: idx, in: sorted, offset: firstTimestamp)
                data.append(ChartDatum(
                    id: event.id,
                    lane: .assistant,
                    startTime: relative,
                    endTime: end,
                    color: Color(hex: EventType.assistantMessage.colorHex) ?? .blue,
                    eventType: .assistantMessage,
                    toolRunning: false,
                    label: event.content
                ))

            case .toolStart:
                if let toolID = event.toolID {
                    openTools[toolID] = (start: relative, eventID: event.id, name: event.toolName)
                }

            case .toolEnd:
                if let toolID = event.toolID,
                   let open = openTools.removeValue(forKey: toolID) {
                    // Completed tool call — green bar.
                    data.append(ChartDatum(
                        id: open.eventID,               // links back to the .toolStart event
                        lane: .tool,
                        startTime: open.start,
                        endTime: relative,
                        color: Color(hex: EventType.toolEnd.colorHex) ?? .green,
                        eventType: .toolEnd,
                        toolRunning: false,
                        label: open.name
                    ))
                }

            case .reasoningBlock:
                let end = endTime(forIndex: idx, in: sorted, offset: firstTimestamp)
                data.append(ChartDatum(
                    id: event.id,
                    lane: .reasoning,
                    startTime: relative,
                    endTime: end,
                    color: Color(hex: EventType.reasoningBlock.colorHex) ?? .red,
                    eventType: .reasoningBlock,
                    toolRunning: false,
                    label: nil
                ))

            case .turnBoundary:
                // Omitted from the chart.
                break
            }
        }

        // ── Running tool calls (no `.toolEnd` received) ──
        for (_, open) in openTools {
            data.append(ChartDatum(
                id: open.eventID,
                lane: .tool,
                startTime: open.start,
                endTime: totalDuration,                 // spans to end of session
                color: Color(hex: EventType.toolStart.colorHex) ?? .orange,
                eventType: .toolStart,
                toolRunning: true,
                label: open.name
            ))
        }

        return data
    }

    /// The end-time for an event that implicitly spans until the next event (or session end).
    private func endTime(
        forIndex idx: Int,
        in sorted: [SessionTimelineEvent],
        offset firstTimestamp: TimeInterval
    ) -> TimeInterval {
        if idx + 1 < sorted.count {
            return sorted[idx + 1].timestamp.timeIntervalSince1970 - firstTimestamp
        }
        return max(totalDuration, 0.001)   // ensure non-zero width for the final bar
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    PlaybackTimelineChartPreviews.previews
}

enum PlaybackTimelineChartPreviews {
    static var previews: some View {
        PlaybackTimelineChartInternalPreview()
            .preferredColorScheme(.dark)
            .frame(width: 700, height: 340)
            .padding()
    }
}

/// Internal wrapper that manages the selection binding for the preview.
private struct PlaybackTimelineChartInternalPreview: View {
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Timeline")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            PlaybackTimelineChart(
                events: mockEvents,
                totalDuration: 42.0,
                selectedEventID: $selectedID
            )

            if let id = selectedID {
                Text("Selected: \(id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Tap a bar or dot to select")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    // ── Mock Data (8 events covering all four lanes) ──

    private var mockEvents: [SessionTimelineEvent] {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        func ev(_ secs: TimeInterval, _ type: EventType, id: String,
                content: String? = nil, toolName: String? = nil,
                toolID: String? = nil) -> SessionTimelineEvent {
            SessionTimelineEvent(
                id: id,
                type: type,
                timestamp: base.addingTimeInterval(secs),
                content: content,
                toolName: toolName,
                toolID: toolID,
                durationMs: nil,
                tokenCount: nil,
                summary: nil
            )
        }

        return [
            // Turn 1
            ev(0.5,  .userMessage,      id: "u1", content: "Hello"),
            ev(1.0,  .assistantMessage, id: "a1", content: "Hi! How can I help?"),
            ev(2.0,  .toolStart,        id: "t1s", toolName: "search", toolID: "tool-1"),
            ev(7.0,  .toolEnd,          id: "t1e", toolName: "search", toolID: "tool-1"),
            ev(7.5,  .assistantMessage, id: "a2", content: "I found 3 results."),

            // Turn 2
            ev(10.0, .userMessage,      id: "u2", content: "Explain reasoning"),
            ev(11.0, .reasoningBlock,   id: "r1"),
            ev(14.0, .assistantMessage, id: "a3", content: "Step 1: analyze…"),
            ev(15.0, .toolStart,        id: "t2s", toolName: "fetch", toolID: "tool-2"),
            ev(19.0, .toolEnd,          id: "t2e", toolName: "fetch", toolID: "tool-2"),
            ev(19.5, .reasoningBlock,   id: "r2"),
            ev(22.0, .assistantMessage, id: "a4", content: "Here’s the final answer."),

            // Turn 3 — running tool (no end)
            ev(25.0, .userMessage,      id: "u3", content: "Run analysis"),
            ev(26.0, .toolStart,        id: "t3s", toolName: "analyze", toolID: "tool-3"),
            ev(30.0, .assistantMessage, id: "a5", content: "Analysis in progress…"),
            ev(35.0, .reasoningBlock,   id: "r3"),
            ev(40.0, .assistantMessage, id: "a6", content: "Almost done."),
        ]
    }
}
#endif
