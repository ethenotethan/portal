import SwiftUI

// MARK: - ThoughtGraphNodeView

/// Renders a single node card in the thought graph timeline.
///
/// Three visual flavors:
/// - **Tool call** — bordered card tinted by category, path subtitle.
/// - **Reasoning beat** — quiet borderless "thought" card, italic label.
/// - **Agent** — pink-accented card with model chip; when its loop is
///   collapsed, shows a step-count badge instead of the goal line.
///
/// Used both inside the Canvas (via `ImageRenderer` snapshot) and as a
/// stand-alone header card in the detail popover.
struct ThoughtGraphNodeView: View {
    let node: ThoughtGraphNode
    let layout: ThoughtGraphLayout
    let isSelected: Bool
    let isHovered: Bool
    /// Non-nil when this agent node's loop is collapsed: the hidden step count.
    var collapsedStepCount: Int?

    private var isReasoning: Bool { node.category == .reasoning }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 2) {
            // ── Line 1: status icon + name ──
            HStack(spacing: 6) {
                statusIcon
                    .frame(width: 14, height: 14)

                Text(displayName)
                    .font(.system(.caption, design: isReasoning ? .default : .monospaced))
                    .italic(isReasoning)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                trailingChip
            }

            // ── Line 2: subtitle ──
            subtitle
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: layout.width, height: layout.height)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: shadowColor,
            radius: isSelected ? 7 : 3, x: 0, y: 2
        )
        .scaleEffect(isHovered && !isSelected ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var trailingChip: some View {
        if let steps = collapsedStepCount {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                Text("\(steps)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.agentAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.agentAccent.opacity(0.16), in: Capsule())
        } else if node.isAgent, let model = node.modelName, !model.isEmpty {
            Text(shortModelName(model))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.agentAccent.opacity(0.9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.agentAccent.opacity(0.14), in: Capsule())
        } else if node.isComplete, let dur = node.durationSeconds, !isReasoning {
            Text(DurationFormatter.short(dur))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.surface, in: Capsule())
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if node.isAgent {
            if collapsedStepCount != nil {
                Text("loop collapsed")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let goal = node.context, !goal.isEmpty {
                Text(goal)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if isReasoning {
            if let reasoning = node.summary, !reasoning.isEmpty {
                Text(reasoning)
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let contextPath = node.extractedFilePath {
            Text(contextPath)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private var displayName: String {
        if node.isAgent { return "agent" }
        if isReasoning, let context = node.context, !context.isEmpty {
            return String(context.prefix(24))
        }
        return node.name.count <= 18 ? node.name : String(node.name.prefix(16)) + "…"
    }

    /// "claude-sonnet-5" → "sonnet-5" style compaction for the node chip.
    private func shortModelName(_ model: String) -> String {
        let trimmed = model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "us.anthropic.", with: "")
        return trimmed.count <= 12 ? trimmed : String(trimmed.prefix(11)) + "…"
    }

    // MARK: - Styling

    private var categoryColor: Color { node.category.color }

    private var titleColor: Color {
        if node.isAgent { return Theme.agentAccent }
        if isReasoning { return Theme.secondary }
        return Theme.primary
    }

    /// Subtle vertical gradient instead of a flat fill for depth.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: isReasoning
                        ? [Theme.surface.opacity(0.55), Theme.surface.opacity(0.35)]
                        : [
                            categoryColor.opacity(node.status == .error ? 0.22 : 0.20),
                            categoryColor.opacity(node.status == .error ? 0.12 : 0.08),
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    @ViewBuilder
    private var cardBorder: some View {
        if isReasoning && !isSelected {
            // Thought beats stay borderless — quiet by design.
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: borderWidth)
        }
    }

    private var borderColor: Color {
        if isSelected { return Theme.accent }
        switch node.status {
        case .running:  return categoryColor.opacity(0.55)
        case .completed: return categoryColor.opacity(0.35)
        case .error:     return Color.red.opacity(0.5)
        }
    }

    private var borderWidth: CGFloat {
        isSelected ? 2.0 : (isHovered ? 1.5 : 1.0)
    }

    private var shadowColor: Color {
        if isSelected { return Theme.accent.opacity(0.35) }
        if isReasoning { return .clear }
        return Color.black.opacity(0.25)
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch node.status {
        case .running:
            if node.isAgent {
                if #available(macOS 15.0, iOS 18.0, *) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(categoryColor)
                        .symbolEffect(.pulse, options: .speed(1.2))
                } else {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(categoryColor)
                }
            } else if #available(macOS 15.0, iOS 18.0, *) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(categoryColor)
                    .symbolEffect(.rotate, options: .speed(0.5))
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(categoryColor)
            }
        case .completed:
            Image(systemName: iconForCompleted)
                .font(.caption)
                .foregroundStyle(categoryColor.opacity(0.8))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.red)
        }
    }

    private var iconForCompleted: String {
        if node.isAgent { return "brain" }
        if isReasoning { return "bubble.left" }
        return "checkmark.circle.fill"
    }
}

// MARK: - Duration Formatter

enum DurationFormatter {
    /// Format seconds as a compact human-readable string, e.g. "0.8s", "1.2s".
    static func short(_ seconds: Double) -> String {
        let rounded = (seconds * 10).rounded() / 10
        return String(format: "%.1fs", rounded)
    }
}

// MARK: - Previews

#if DEBUG
struct ThoughtGraphNodeViewPreviews: PreviewProvider {
    static var previews: some View {
        let layout = ThoughtGraphLayout(
            nodeID: "preview", x: 0, y: 0,
            width: ThoughtGraphLayoutEngine.nodeSize.width,
            height: ThoughtGraphLayoutEngine.nodeSize.height
        )

        VStack(spacing: 16) {
            ThoughtGraphNodeView(
                node: .runningSample, layout: layout,
                isSelected: false, isHovered: false
            )
            ThoughtGraphNodeView(
                node: .completedSample, layout: layout,
                isSelected: true, isHovered: false
            )
            ThoughtGraphNodeView(
                node: .reasoningSample, layout: layout,
                isSelected: false, isHovered: false
            )
            ThoughtGraphNodeView(
                node: .agentSample, layout: layout,
                isSelected: false, isHovered: false
            )
            ThoughtGraphNodeView(
                node: .agentSample, layout: layout,
                isSelected: false, isHovered: false,
                collapsedStepCount: 12
            )
            ThoughtGraphNodeView(
                node: .errorSample, layout: layout,
                isSelected: false, isHovered: true
            )
        }
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

private extension ThoughtGraphNode {
    static let runningSample = ThoughtGraphNode(
        id: "tool_1",
        name: "search_files",
        context: "Searching for SwiftUI Canvas patterns...",
        isComplete: false
    )

    static let completedSample = ThoughtGraphNode(
        id: "tool_2",
        name: "read_file",
        context: nil,
        summary: "Read 120 lines",
        isComplete: true,
        durationSeconds: 0.85
    )

    static let reasoningSample = ThoughtGraphNode(
        id: "reasoning-1",
        name: "reasoning",
        context: "Choose layout strategy",
        summary: "Swimlanes beat force-directed for timelines.",
        isComplete: true
    )

    static let agentSample = ThoughtGraphNode(
        id: "agent-s1",
        name: "agent",
        context: "Audit reconnect handling for races",
        isComplete: false,
        agentID: "s1",
        modelName: "claude-sonnet-5"
    )

    static let errorSample = ThoughtGraphNode(
        id: "tool_3",
        name: "patch",
        context: "Applying diff...",
        isComplete: true,
        isError: true,
        durationSeconds: 2.1
    )
}
#endif
