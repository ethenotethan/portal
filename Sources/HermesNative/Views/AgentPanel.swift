import SwiftUI
import Lottie

/// Two-column agent panel shown during streaming.
/// Left column: Lottie animated character reacting to tool cascade.
/// Right column: stacked tool call pills.
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

    private var characterExpression: CharacterExpression {
        switch avatarState {
        case .idle:     return .idle
        case .thinking: return .thinking
        case .speaking: return .happy
        case .toolUse:  return .thinking
        case .error:    return .confused
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left: Lottie animated character
            LottieCharacterView(
                expression: characterExpression,
                size: CGSize(width: 160, height: 160)
            )
            .frame(width: 160)

            // Right: Tool pills + status
            VStack(alignment: .leading, spacing: Theme.pillSpacing) {
                // State label
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

                // Tool pills
                ForEach(orderedTools) { tool in
                    ToolPillView(tool: tool, isRunning: !tool.isComplete)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .foregroundStyle(Theme.accent)
            .onReceive(timer) { _ in
                frame = (frame + 1) % frames.count
            }
    }
}
