import SwiftUI

/// Vertical flow diagram showing a SpawnNode's tool invocations in sequence.
/// Each tool call is a card with name, duration, preview, and summary,
/// connected by downward arrows.
struct ToolCallFlowView: View {
    let node: SpawnNode

    var body: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            VStack(spacing: 0) {
                // Agent goal / task header
                agentHeader

                if !node.toolCalls.isEmpty {
                    Divider()
                        .background(Theme.border)
                        .padding(.vertical, 12)

                    ForEach(Array(node.toolCalls.enumerated()), id: \.element.id) { index, toolCall in
                        toolCallCard(toolCall, index: index)

                        if index < node.toolCalls.count - 1 {
                            flowArrow
                        }
                    }
                } else {
                    Divider()
                        .background(Theme.border)
                        .padding(.vertical, 12)

                    VStack(spacing: 8) {
                        Image(systemName: "hammer")
                            .font(.title2)
                            .foregroundColor(Theme.tertiary)
                        Text("No tool calls recorded")
                            .font(.caption)
                            .foregroundColor(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            }
            .padding()
            .frame(minWidth: 500)
        }
    }

    // MARK: - Agent Header

    private var agentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(colorForStatus(node.status))
                    .frame(width: 12, height: 12)

                Text(node.goal.isEmpty ? "Root prompt (no goal text)" : node.goal)
                    .font(.headline)
                    .foregroundColor(Theme.primary)
                    .lineLimit(3)

                Spacer()
            }

            HStack(spacing: 12) {
                Label("Depth \(node.depth)", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
                if let model = node.model {
                    Label(model, systemImage: "cpu")
                        .font(.caption)
                        .foregroundColor(Theme.secondary)
                }
                if let cost = node.costUSD {
                    Label(String(format: "$%.4f", cost), systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundColor(Theme.secondary)
                }
                Spacer()
                Label("\(node.toolCalls.count) tools", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tool Call Card

    private func toolCallCard(_ tc: NodeToolCall, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(tc.isComplete ? Theme.success : Theme.accent)
                    )

                Text(tc.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(Theme.accent)

                Spacer()

                if let duration = tc.durationSeconds {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(String(format: "%.1fs", duration))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundColor(Theme.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.background))
                }

                if tc.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(Theme.success)
                }
            }

            // Preview (tool input)
            if let preview = tc.preview, !preview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.tertiary)
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.secondary)
                        .lineLimit(4)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // Summary (tool output)
            if let summary = tc.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.tertiary)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.primary)
                        .lineLimit(6)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Flow Arrow

    private var flowArrow: some View {
        HStack {
            Spacer().frame(width: 10)
            Rectangle()
                .fill(Theme.accent.opacity(0.4))
                .frame(width: 2, height: 32)
            Spacer().frame(width: 10)
        }
        .frame(maxWidth: .infinity)
    }
}
