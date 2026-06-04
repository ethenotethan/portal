import SwiftUI

// MARK: - ThoughtGraphNodeView

/// Renders a single tool-call node in the thought graph DAG visualization.
///
/// Used both inside the Canvas (via `ImageRenderer` snapshot) and as a
/// stand-alone detail card in the popover panel.  The view adapts its
/// appearance based on node status and selection / hover state.
struct ThoughtGraphNodeView: View {
    let node: ThoughtGraphNode
    let layout: ThoughtGraphLayout
    let isSelected: Bool
    let isHovered: Bool

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            // ── Left: status icon ──
            statusIcon
                .frame(width: 16, height: 16)

            // ── Center: tool name ──
            Text(truncatedName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // ── Right: duration badge (completed only) ──
            if node.isComplete, let dur = node.durationSeconds {
                Text(DurationFormatter.short(dur))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: layout.width, height: layout.height)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(
            color: isSelected ? Theme.accent.opacity(0.35) : .clear,
            radius: isSelected ? 6 : 0, x: 0, y: isSelected ? 2 : 0
        )
        .scaleEffect(isHovered && !isSelected ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .opacity(node.status == .running ? pulsingOpacity : 1.0)
        .animation(
            node.status == .running
                ? Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                : .default,
            value: pulsingOpacity
        )
    }

    // MARK: - Helpers

    private var truncatedName: String {
        if node.name.count <= 18 { return node.name }
        return String(node.name.prefix(16)) + "…"
    }

    // MARK: - Styling

    /// Color for the tool category background.
    private var categoryColor: Color {
        switch node.category {
        case .search:   return Theme.warning  // amber
        case .read:     return Theme.accent   // blue/purple
        case .write:    return Theme.success  // green
        case .terminal: return Color.purple
        case .patch:    return Color.orange
        case .other:    return Color.gray
        }
    }

    private var backgroundColor: Color {
        switch node.status {
        case .running:  return categoryColor.opacity(0.18)
        case .completed: return categoryColor.opacity(0.12)
        case .error:     return Color.red.opacity(0.15)
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

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch node.status {
        case .running:
            if #available(macOS 15.0, iOS 18.0, *) {
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
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(categoryColor.opacity(0.8))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.red)
        }
    }

    // MARK: - Pulsing

    @State private var pulsingOpacity: Double = 1.0

    // The pulsing animation is driven by the view appearing when the
    // node is running.  We modulate opacity between 0.6 and 1.0 so the
    // node "breathes" to indicate active work.
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
                node: .errorSample, layout: layout,
                isSelected: false, isHovered: true
            )
            ThoughtGraphNodeView(
                node: .longNameSample, layout: layout,
                isSelected: false, isHovered: false
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
        isComplete: false,
        depth: 1
    )

    static let completedSample = ThoughtGraphNode(
        id: "tool_2",
        name: "read_file",
        context: nil,
        summary: "Read 120 lines",
        isComplete: true,
        durationSeconds: 0.85,
        depth: 1
    )

    static let errorSample = ThoughtGraphNode(
        id: "tool_3",
        name: "patch",
        context: "Applying diff...",
        isComplete: true,
        isError: true,
        durationSeconds: 2.1,
        depth: 2
    )

    static let longNameSample = ThoughtGraphNode(
        id: "tool_4",
        name: "very_long_tool_name_that_exceeds_eighteen_chars",
        context: nil,
        isComplete: true,
        durationSeconds: 0.3,
        depth: 0
    )
}
#endif
