import SwiftUI

/// The "where" lens: a live directory tree of the files a turn TOUCHED, so you
/// can see where the agent is working and how its context accretes — not just
/// the tool bars. Sits beside the timeline; cross-highlights with it via a
/// shared node selection (tap a file → its bars light in the graph; select a
/// bar → its file highlights here).
///
/// Best-effort and honest: built from confidently-parsed paths, labeled
/// "files touched", so a tool with no recognizable path just doesn't appear.
internal struct SessionFileTreePane: View {
    /// The selected turn's composed nodes (same set the flamechart draws).
    internal let nodes: [ThoughtGraphNode]
    /// Shared selection with the timeline (a thought-graph node id).
    @Binding internal var selectedNodeID: String?

    private var roots: [TouchedFileNode] {
        FileTreeAggregator.build(from: nodes)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border.opacity(0.5))
            if roots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(roots) { node in
                            FileTreeRow(node: node, depth: 0, selectedNodeID: $selectedNodeID)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Theme.surface.opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text("Files touched")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text("No files recognized in this turn's tool calls.")
            .font(.caption2)
            .foregroundStyle(Theme.tertiary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row in the file tree — a directory or a file, indented by depth.
/// Directories expand/collapse; files show heat (by action) and cross-select.
private struct FileTreeRow: View {
    let node: TouchedFileNode
    let depth: Int
    @Binding var selectedNodeID: String?
    @State private var expanded = true

    private var isSelected: Bool {
        guard let selectedNodeID else { return false }
        return node.touchingNodeIDs.contains(selectedNodeID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if node.isDirectory && expanded {
                ForEach(node.children) { child in
                    FileTreeRow(node: child, depth: depth + 1, selectedNodeID: $selectedNodeID)
                }
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        HStack(spacing: 5) {
            Spacer().frame(width: CGFloat(depth) * 12)
            if node.isDirectory {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 8)
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondary)
                Text(node.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } else {
                Spacer().frame(width: 8)
                Circle()
                    .fill(heatColor)
                    .frame(width: 6, height: 6)
                Text(node.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.touchCount > 1 {
                    Text("×\(node.touchCount)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } else {
                // Toggle-select: light this file's first touching bar in the graph.
                let first = node.touchingNodeIDs.first
                selectedNodeID = isSelected ? nil : first
            }
        }
    }

    /// File dot color by the hottest action that touched it.
    private var heatColor: Color {
        switch node.dominantAction {
        case .write, .patch: return Theme.graphWrite
        case .search: return Theme.graphSearch
        case .read: return Theme.graphRead
        case .other: return Theme.graphOther
        }
    }
}
