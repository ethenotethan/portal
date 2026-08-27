import SwiftUI

/// Agent panel shown during streaming with status and stacked tool-call pills.
/// Matches the design spec's "Running tools" panel layout.
struct AgentPanel: View {
    let avatarState: AvatarState
    let activeToolCalls: [String: ToolCallRecord]
    let personaName: String

    /// Sorted: running first, then completed
    private var orderedTools: [ToolCallRecord] {
        let running = activeToolCalls.values
            .filter { !$0.isComplete }
            .sorted { $0.id < $1.id }
        let completed = activeToolCalls.values
            .filter { $0.isComplete }
            .sorted { $0.id < $1.id }
        return running + completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.pillSpacing) {
            HStack(spacing: 6) {
                StateSpinner(state: avatarState)
                Text(stateLabel)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Text("·")
                    .foregroundStyle(Theme.tertiary)
                Text(personaName)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 4)

            ForEach(orderedTools) { tool in
                ToolPillView(tool: tool, isRunning: !tool.isComplete)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stateLabel: String {
        switch avatarState {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .speaking: return "Responding"
        case .toolUse: return "Running tools"
        case .error: return "Error"
        }
    }
}

// MARK: - State Spinner

private struct StateSpinner: View {
    let state: AvatarState
    @State private var frame = 0
    private let thinkFrames = ["⠋","⠙","⠹","⸦","⠴","⠦","⠇"]
    private let toolFrames = ["⡇","⣆","⣄","⣰","⢸","⢰","⢠"]
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private var frames: [String] {
        state == .toolUse ? toolFrames : thinkFrames
    }

    var body: some View {
        Text(frames[frame % frames.count])
            .font(.system(.caption, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.accent)
            .onReceive(timer) { _ in
                frame = (frame + 1) % frames.count
            }
    }
}
