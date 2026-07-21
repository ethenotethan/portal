import SwiftUI

/// Pill-shaped tool call row — matches the design spec:
/// Rounded full-pill shape, dark gray bg (#2a2a2a), no border.
/// Wrench icon left, bold tool name, monospace args in dimmer gray.
struct ToolPillView: View {
    let tool: ToolCallRecord
    let isRunning: Bool

    @State private var spinnerFrame = 0
    private let toolFrames = ["⡇","⣆","⣄","⣰","⢸","⢰","⢠"]
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            // Wrench icon (or spinner for running tools)
            if isRunning && !tool.isComplete {
                Text(toolFrames[spinnerFrame % toolFrames.count])
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 16)
                    .onReceive(timer) { _ in
                        spinnerFrame = (spinnerFrame + 1) % toolFrames.count
                    }
            } else {
                Image(systemName: "checkmark")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 16)
            }

            // Tool name
            Text(tool.name)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Theme.primary)

            if let risk = tool.riskLevel {
                ToolRiskChip(tool: tool, risk: risk)
            }

            // Separator
            Text("—")
                .font(.system(.caption2))
                .foregroundStyle(Theme.tertiary)

            // Args / context
            Text(toolContext)
                .font(.system(.caption, design: .default))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Duration (completed)
            if tool.isComplete, let duration = tool.durationSeconds {
                Text(String(format: "%.1fs", duration))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.pillRadius))
    }

    private var toolContext: String {
        if let summary = tool.summary, !summary.isEmpty {
            return summary
        }
        if let context = tool.context, !context.isEmpty {
            return context
        }
        return ""
    }
}
