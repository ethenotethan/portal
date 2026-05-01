import SwiftUI

/// Recursive view that renders a single node in the spawn tree and its children.
/// Nodes are laid out vertically with indented children connected by lines.
struct TreeNodeView: View {
    @ObservedObject var node: SpawnNode
    let depth: Int
    let maxDepth: Int
    @Binding var selectedNodeID: String?
    let onNodeTap: (SpawnNode) -> Void
    let onNodeLongPress: (SpawnNode) -> Void

    private let indentation: CGFloat = 28
    private let connectorWidth: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // This node
            nodeRow
                .contentShape(Rectangle())
                .onTapGesture { onNodeTap(node) }

            // Children (if within depth limit)
            if depth < maxDepth && !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                        HStack(alignment: .top, spacing: 0) {
                            // Connector line
                            connectorLine(isLast: index == node.children.count - 1)

                            // Child node
                            TreeNodeView(
                                node: child,
                                depth: depth + 1,
                                maxDepth: maxDepth,
                                selectedNodeID: $selectedNodeID,
                                onNodeTap: onNodeTap,
                                onNodeLongPress: onNodeLongPress
                            )
                        }
                    }
                }
                .padding(.leading, indentation)
            } else if depth >= maxDepth && !node.children.isEmpty {
                // Depth limit reached — show collapsed indicator
                collapsedIndicator
                    .padding(.leading, indentation + 8)
            }
        }
    }

    // MARK: - Node Row

    private var nodeRow: some View {
        HStack(spacing: 10) {
            // Status icon
            Image(systemName: node.status.iconName)
                .font(.body)
                .foregroundStyle(colorForStatus(node.status))
                .opacity(node.status == .running ? 1 : 0.7)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Goal (truncated)
                Text(String(node.goal.prefix(80)))
                    .font(.subheadline)
                    .fontWeight(selectedNodeID == node.id ? .semibold : .regular)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)

                // Metadata row
                HStack(spacing: 8) {
                    // Model
                    if let model = node.model {
                        Text(shortModel(model))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Depth badge
                    if depth > 0 {
                        Text("L\(depth)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Duration
                    if node.status.isTerminal || node.status == .running {
                        Label(node.durationString, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Tool count
                    if !node.toolCalls.isEmpty {
                        Label("\(node.toolCalls.count)", systemImage: "wrench")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Child count
                    if !node.children.isEmpty {
                        Label("\(node.children.count)", systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Cost
                    if let cost = node.costUSD, cost > 0 {
                        Text(String(format: "$%.4f", cost))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Tokens
                    if let tokens = node.totalTokens {
                        Text("\(tokens) tok")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            // Running indicator
            if node.status == .running {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(0.7)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedNodeID == node.id ? Theme.surfaceHover : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onNodeLongPress(node) }
        )
    }

    // MARK: - Connector Line

    private func connectorLine(isLast: Bool) -> some View {
        VStack(spacing: 0) {
            // Vertical line from top
            Rectangle()
                .fill(Theme.border)
                .frame(width: connectorWidth, height: 14)

            // Horizontal branch + continuing vertical (or not)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 12, height: connectorWidth)

                if !isLast {
                    // Continue vertical line down
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: connectorWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            .offset(y: -1)

            Spacer(minLength: 0)
        }
        .frame(width: 14)
    }

    // MARK: - Collapsed Indicator

    private var collapsedIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("\(node.children.count) more")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func shortModel(_ model: String) -> String {
        // Trim common prefixes
        let trimmed = model
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "openrouter/", with: "")
        return String(trimmed.prefix(20))
    }
}
