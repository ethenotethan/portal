import SwiftUI
import Charts

struct SessionRunTimelineView: View {
    let events: [SessionRunEvent]

    private var completedEvents: [SessionRunEvent] {
        events.filter { $0.endedAt != nil }
            .sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if completedEvents.isEmpty {
                emptyState
            } else {
                durationChart
                tokenChart
                runHistoryList
            }
        }
    }

    // MARK: - Duration Chart

    private var durationChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run Duration")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            Chart(completedEvents) { event in
                BarMark(
                    x: .value("Run", event.startedAt, unit: .minute),
                    y: .value("Duration (s)", event.duration ?? 0)
                )
                .foregroundStyle(event.status == .failed ? Color.red.gradient : Theme.accent.gradient)
                .cornerRadius(3)
            }
            .chartYAxisLabel("Seconds")
            .frame(height: 220)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Token Chart

    private var tokenChart: some View {
        let hasTokens = completedEvents.contains { $0.totalTokens > 0 }
        guard hasTokens else { return AnyView(EmptyView()) }

        return AnyView(VStack(alignment: .leading, spacing: 8) {
            Text("Token Usage Over Time")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            Chart {
                ForEach(completedEvents) { event in
                    LineMark(
                        x: .value("Run", event.startedAt),
                        y: .value("Input", event.inputTokens)
                    )
                    .foregroundStyle(Color.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    LineMark(
                        x: .value("Run", event.startedAt),
                        y: .value("Output", event.outputTokens)
                    )
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Run", event.startedAt),
                        y: .value("Total", event.totalTokens)
                    )
                    .foregroundStyle(Theme.accent.opacity(0.1))
                }
            }
            .frame(height: 220)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)))
    }

    // MARK: - Run List

    private var runHistoryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run History")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            let recent = Array(events.prefix(20))
            ForEach(recent) { event in
                runRow(event)
            }
        }
    }

    private func runRow(_ event: SessionRunEvent) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(event.status == .failed ? Color.red : event.status == .running ? Theme.success : Theme.accent.opacity(0.5))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.startedAt, style: .time)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.primary)

                    if let endedAt = event.endedAt {
                        Text("→")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                        Text(endedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }

                    Text(event.durationLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.1), in: Capsule())
                }

                if event.totalTokens > 0 {
                    Text("\(event.inputTokens) in / \(event.outputTokens) out / \(event.totalTokens) total")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
            }

            Spacer()

            if let cost = event.costUSD, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.warning)
            }

            if event.status == .running {
                PulsingDot(color: Theme.success)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.surfaceHover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiary)
            Text("No run history yet")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text("Runs will be tracked as you chat with the agent.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(30)
    }
}
