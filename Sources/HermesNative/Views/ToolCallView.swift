import SwiftUI

/// Renders a single tool invocation as a compact card.
struct ToolCallView: View {
    let toolCall: ToolCallRecord

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Icon
            Image(systemName: toolCall.isComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(toolCall.isComplete ? .green : Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                // Tool name + duration
                HStack(spacing: 4) {
                    Text(toolCall.name)
                        .font(.caption)
                        .fontWeight(.medium)

                    if let duration = toolCall.durationSeconds {
                        Text(String(format: "%.1fs", duration))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Context/summary
                if let summary = toolCall.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let context = toolCall.context, !context.isEmpty {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Inline diff (collapsible)
                if let diff = toolCall.inlineDiff, !diff.isEmpty {
                    InlineDiffView(text: diff)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Inline Diff View

struct InlineDiffView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Diff", isExpanded: $isExpanded) {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isExpanded ? 200 : nil)
        }
        .font(.caption2)
    }
}
