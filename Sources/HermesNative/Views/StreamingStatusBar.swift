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

            // Live tool call list
            if !activeToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(runningTools) { tool in
                        HStack(spacing: 4) {
                            Text("├─")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.quaternary)
                            Text(toolFrames[spinnerFrame % toolFrames.count])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.amber)
                            Text(tool.name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.medium)
                                .foregroundStyle(accentColor)
                            if let context = tool.context, !context.isEmpty {
                                Text("·").foregroundStyle(.tertiary)
                                Text(context)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    ForEach(completedTools) { tool in
                        HStack(spacing: 4) {
                            Text("├─")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.quaternary)
                            Text("✓")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.green)
                            Text(tool.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let duration = tool.durationSeconds {
                                Text(String(format: "%.1fs", duration))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            if let summary = tool.summary, !summary.isEmpty {
                                Text("·").foregroundStyle(.tertiary)
                                Text(summary)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.leading, 20)
        .padding(.vertical, 4)
    }
}
