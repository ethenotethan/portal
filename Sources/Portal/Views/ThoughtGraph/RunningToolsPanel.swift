import SwiftUI

/// The "running tools" lens as a standalone panel: the turn's tool calls as a
/// list — active ones first (with a spinner), then completed (with duration) —
/// so the user can watch the trace without reading it off the flamechart bars.
///
/// Reasoning beats and subagent nodes are excluded; this panel is specifically
/// the tool trace. Derived purely from the turn's nodes (no engine, no timer),
/// so it re-renders only when the node set changes.
internal struct RunningToolsPanel: View {
    internal let nodes: [ThoughtGraphNode]
    /// Cross-highlight selection shared with the flamechart / file tree.
    internal var selection: Binding<String?>?

    private var toolNodes: [ThoughtGraphNode] {
        nodes.filter { $0.category != .reasoning && !$0.isAgent }
    }

    private var running: [ThoughtGraphNode] {
        toolNodes.filter { !$0.isComplete }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    private var completed: [ThoughtGraphNode] {
        toolNodes.filter { $0.isComplete }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    internal var body: some View {
        if toolNodes.isEmpty {
            PanelEmptyState(icon: "wrench.and.screwdriver", message: "No tools run this turn")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(running) { toolRow($0, isRunning: true) }
                    ForEach(completed) { toolRow($0, isRunning: false) }
                }
                .padding(8)
            }
        }
    }

    private func toolRow(_ node: ThoughtGraphNode, isRunning: Bool) -> some View {
        let isSelected = selection?.wrappedValue == node.id
        return HStack(spacing: 8) {
            statusGlyph(node, isRunning: isRunning)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(node.category.color)
                if let sub = subtitle(node) {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let secs = node.durationSeconds, node.isComplete {
                Text(format(secs))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected ? Theme.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard let selection else { return }
            selection.wrappedValue = isSelected ? nil : node.id
        }
    }

    @ViewBuilder
    private func statusGlyph(_ node: ThoughtGraphNode, isRunning: Bool) -> some View {
        if node.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warning)
        } else if isRunning {
            Image(systemName: "circle.dotted")
                .font(.system(size: 10))
                .foregroundStyle(node.category.color)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.success.opacity(0.8))
        }
    }

    private func subtitle(_ node: ThoughtGraphNode) -> String? {
        let raw = node.summary ?? node.context
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text.components(separatedBy: "\n").first
    }

    private func format(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%.0fm%02.0fs", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }
}
