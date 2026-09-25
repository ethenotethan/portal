import SwiftUI

/// TUI-aligned streaming status bar — braille spinner + state label + live tool calls.
/// Used by the TUI skin to show streaming progress.
struct StreamingStatusBar: View {
    let state: AvatarState
    let activeToolCalls: [String: ToolCallRecord]
    let personaName: String
    let accentColor: Color

    @State private var spinnerFrame = 0
    private let thinkFrames = ["⠋","⠙","⠹","⸦","⠴","⠦","⠇"]
    private let toolFrames = ["⡇","⣆","⣄","⣰","⢸","⢰","⢠"]
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private var currentFrames: [String] {
        switch state {
        case .thinking: return thinkFrames
        case .toolUse: return toolFrames
        default: return thinkFrames
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "idle"
        case .thinking: return "Thinking"
        case .speaking: return "Responding"
        case .toolUse: return "Running tools"
        case .error: return "Error"
        }
    }

    /// Sorted list of active (incomplete) tool calls
    private var runningTools: [ToolCallRecord] {
        activeToolCalls.values
            .filter { !$0.isComplete }
            .sorted { $0.id < $1.id }
    }

    /// Sorted list of completed tool calls
    private var completedTools: [ToolCallRecord] {
        activeToolCalls.values
            .filter { $0.isComplete }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top line: spinner + state + persona
            HStack(spacing: 6) {
                Text(currentFrames[spinnerFrame % currentFrames.count])
                    .font(.system(.body, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(accentColor)
                    .onReceive(timer) { _ in
                        spinnerFrame = (spinnerFrame + 1) % currentFrames.count
                    }

                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(personaName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(accentColor)
            }

            // Live tool call list — each row expands to the tool's context and
            // (once complete) its summary, so the running turn's tool calls are
            // inspectable live instead of name-only text.
            if !activeToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(runningTools) { tool in
                        ExpandableToolRow(tool: tool, spinnerFrame: spinnerFrame, toolFrames: toolFrames)
                    }

                    ForEach(completedTools) { tool in
                        ExpandableToolRow(tool: tool, spinnerFrame: spinnerFrame, toolFrames: toolFrames)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, Theme.bubblePaddingH)
        .padding(.vertical, Theme.bubblePaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }
}

/// One live tool row in the streaming status bar. Collapsed: the TUI-style
/// `├─ ⠿ name · context` line. Expanded: plus the summary (when complete) and
/// the full context. Expansion state is per-row @State and survives the
/// transcript's scroll/recycle churn (no onAppear reset).
private struct ExpandableToolRow: View {
    let tool: ToolCallRecord
    let spinnerFrame: Int
    let toolFrames: [String]

    @State private var isExpanded = false

    private var headline: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            if tool.isComplete {
                Text("✓")
                    .font(.system(.caption2, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(.green)
            } else {
                Text(toolFrames[spinnerFrame % toolFrames.count])
                    .font(.system(.caption2, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Color.amber)
            }
            Text(tool.name)
                .font(.system(.caption, design: .monospaced))
                .monospaced()
                .fontWeight(.medium)
                .foregroundStyle(tool.isComplete ? .secondary : .primary)
            if let duration = tool.durationSeconds {
                Text(String(format: "%.1fs", duration))
                    .font(.system(.caption2, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(.tertiary)
            }
            if let context = tool.context, !context.isEmpty, !isExpanded {
                Text("·").foregroundStyle(.tertiary)
                Text(context)
                    .font(.system(.caption2, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("├─")
                    .font(.system(.caption, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(.quaternary)
                headline
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let context = tool.context, !context.isEmpty {
                        Text(context)
                            .font(.system(.caption2, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let summary = tool.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(.caption2, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(.tertiary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}
