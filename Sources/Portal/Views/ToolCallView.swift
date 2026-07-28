import SwiftUI

// MARK: - Tool Trail (TUI-aligned tree rendering)

/// Renders a sequence of tool calls as a tree with ├─/└─ branches,
/// matching the TUI's ToolTrail component.
struct ToolTrailView: View {
    let tools: [ToolCallRecord]
    let reasoning: String?
    let reasoningTokens: Int?
    let toolTokens: Int?
    let isStreaming: Bool

    @State private var reasoningExpanded: Bool = false
    @State private var toolsExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thinking/Reasoning section
            if let reasoning = reasoning, !reasoning.isEmpty {
                ChevronRow(
                    title: isStreaming ? "Thinking" : "Reasoning",
                    count: nil,
                    isExpanded: $reasoningExpanded,
                    spinner: isStreaming,
                    accentColor: .orange
                )

                if reasoningExpanded {
                    TreeBranch(isLast: tools.isEmpty && !isStreaming) {
                        Text(reasoning)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.trailing, 8)
                    }
                }
            }

            // Tool calls section
            if !tools.isEmpty {
                ChevronRow(
                    title: "Tool calls",
                    count: tools.count,
                    isExpanded: $toolsExpanded,
                    spinner: tools.contains(where: { !$0.isComplete }),
                    accentColor: .amber
                )

                if toolsExpanded {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        TreeBranch(isLast: index == tools.count - 1) {
                            ToolRow(tool: tool)
                        }
                    }
                }
            }
        }
        .font(.caption)
        .onAppear {
            if isStreaming { reasoningExpanded = true }
        }
    }
}

// MARK: - Tool Row (single tool call in the tree)

struct ToolRow: View {
    let tool: ToolCallRecord
    @State private var diffExpanded = false
    @State private var findingsExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // Status dot
            Circle()
                .fill(tool.isComplete ? Color.green : Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                // Tool name + duration
                HStack(spacing: 4) {
                    Text(tool.name)
                        .fontWeight(.medium)

                    if let duration = tool.durationSeconds {
                        Text(String(format: "%.1fs", duration))
                            .foregroundStyle(.tertiary)
                    }

                    if let risk = tool.riskLevel {
                        ToolRiskChip(tool: tool, risk: risk)
                    }

                    if !tool.isComplete {
                        PortalProgressView()
                    }
                }

                // Output-risk findings (collapsible)
                if let findings = tool.riskFindings, !findings.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            findingsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: findingsExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Findings (\(findings.count))")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    if findingsExpanded {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(findings, id: \.self) { finding in
                                Text("• \(finding)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                // Summary or context
                if let summary = tool.summary, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if let context = tool.context, !context.isEmpty {
                    Text(context)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Inline diff (collapsible)
                if let diff = tool.inlineDiff, !diff.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            diffExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: diffExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Diff")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    if diffExpanded {
                        ScrollView {
                            Text(diff)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }
            }
        }
    }
}

// MARK: - Tool Risk Chip (output-security scanner verdict)

/// Small colored chip flagging a tool call's scanned output risk, with the
/// findings summarized in a tooltip and a "redacted" marker when the
/// gateway stripped content.
struct ToolRiskChip: View {
    let tool: ToolCallRecord
    let risk: ToolRiskLevel

    private var chipColor: Color {
        switch risk {
        case .low: .green
        case .medium: .yellow
        case .high: .red
        }
    }

    private var tooltip: String {
        let findings = tool.riskFindings ?? []
        guard !findings.isEmpty else { return "Output risk: \(risk.rawValue)" }
        return findings.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 8))
            Text(risk.rawValue)
                .font(.caption2.weight(.semibold))
            if tool.riskRedacted == true {
                Text("· redacted")
                    .font(.caption2)
            }
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(chipColor.opacity(0.15), in: Capsule())
        .help(tooltip)
        .accessibilityLabel("Output risk \(risk.rawValue)")
    }
}

// MARK: - Tree Branch (├─ / └─ rails)

struct TreeBranch<Content: View>: View {
    let isLast: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Tree rail
            Text(isLast ? "└─ " : "├─ ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 28, alignment: .leading)

            content
        }
    }
}

// MARK: - Chevron Row (▸/▾ section header)

struct ChevronRow: View {
    let title: String
    let count: Int?
    @Binding var isExpanded: Bool
    let spinner: Bool
    let accentColor: Color

    @State private var spinnerFrame = 0
    private let spinnerFrames = ["⠋","⠙","⠹","⸦","⠴","⠦","⠇"]
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "▾ " : "▸ ")
                    .foregroundStyle(accentColor)
                    .font(.system(.caption, design: .monospaced))

                if spinner {
                    Text(spinnerFrames[spinnerFrame % spinnerFrames.count])
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(accentColor)
                        .onReceive(timer) { _ in
                            spinnerFrame = (spinnerFrame + 1) % spinnerFrames.count
                        }
                }

                Text(title)
                    .foregroundStyle(.secondary)

                if let count = count {
                    Text("(\(count))")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color extension for amber

extension Color {
    static var amber: Color { Color(red: 0.85, green: 0.65, blue: 0.13) }
}

// MARK: - Legacy compatibility

/// Renders a single tool invocation (kept for MessageBubbleView compat).
struct ToolCallView: View {
    let toolCall: ToolCallRecord

    var body: some View {
        ToolRow(tool: toolCall)
    }
}
