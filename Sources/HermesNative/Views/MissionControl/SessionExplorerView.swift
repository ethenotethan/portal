import SwiftUI

/// Drill-in view for a single session — shows the spawn tree as a node graph.
/// Presented as a sheet on long-press of a session row.
struct SessionExplorerView: View {
    let sessionID: String
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss
    @State private var selectedNodeID: String?
    @State private var showTranscriptFor: SpawnNode?
    @State private var expandDepth: Int = 3

    private var tree: SessionTree? {
        spawnTreeStore.sessions.first { $0.sessionID == sessionID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let tree {
                    treeContent(tree: tree)
                } else {
                    emptyState
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Stepper("Depth: \(expandDepth)", value: $expandDepth, in: 0...10)
                        .font(.caption)
                    if let tree {
                        interruptButton(tree: tree)
                    }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $showTranscriptFor) { node in
                NodeTranscriptSheet(node: node)
            }
        }
    }

    // MARK: - Tree Content

    private func treeContent(tree: SessionTree) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                // HUD
                sessionHUD(tree: tree)

                // Spawn tree
                TreeNodeView(
                    node: tree.root,
                    depth: 0,
                    maxDepth: expandDepth,
                    selectedNodeID: $selectedNodeID,
                    onNodeTap: { node in
                        selectedNodeID = node.id
                    },
                    onNodeLongPress: { node in
                        showTranscriptFor = node
                    }
                )
            }
            .padding()
        }
        .navigationTitle(tree.root.goal.isEmpty ? "Mission Control" : String(tree.root.goal.prefix(50)))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Spawn Tree Yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This session hasn't spawned any subagents. Start a task that uses delegation to see the tree grow.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .navigationTitle("Mission Control")
    }

    // MARK: - HUD (iOS-friendly: wrapping HStack → flow layout)

    private func sessionHUD(tree: SessionTree) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: status + counts
            HStack(spacing: 12) {
                Label {
                    Text(tree.root.status.rawValue.capitalized)
                } icon: {
                    Image(systemName: tree.root.status.iconName)
                        .foregroundStyle(colorForStatus(tree.root.status))
                }
                .font(.subheadline)

                if tree.isRunning {
                    Label("\(tree.root.runningDescendantCount) active", systemImage: "circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                }

                Label("\(tree.nodeCount) nodes", systemImage: "arrow.triangle.branch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Row 2: cost + duration + model
            HStack(spacing: 12) {
                if tree.totalCost > 0 {
                    Label(String(format: "$%.4f", tree.totalCost), systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label(tree.root.durationString, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let model = tree.root.model ?? tree.root.allDescendants.first?.model {
                    Text(shortModel(model))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Interrupt

    private func interruptButton(tree: SessionTree) -> some View {
        Button {
            Task {
                guard case .connected = gatewayClientWrapper.client.connectionState else { return }
                try? await gatewayClientWrapper.client.interrupt(sessionID: tree.sessionID)
            }
        } label: {
            Label("Interrupt", systemImage: "stop.fill")
        }
        .disabled(!tree.isRunning)
    }

    private func shortModel(_ model: String) -> String {
        let trimmed = model
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "openrouter/", with: "")
        return String(trimmed.prefix(20))
    }
}

// MARK: - Node Transcript Sheet

struct NodeTranscriptSheet: View {
    @ObservedObject var node: SpawnNode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    nodeHeader

                    Divider()

                    if !node.thinkingText.isEmpty {
                        Section("Thinking") {
                            Text(node.thinkingText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if !node.toolCalls.isEmpty {
                        Section("Tool Calls") {
                            ForEach(node.toolCalls) { tool in
                                HStack(spacing: 8) {
                                    Image(systemName: tool.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                                        .foregroundStyle(tool.isComplete ? Theme.success : .secondary)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        if let preview = tool.preview {
                                            Text(preview)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .padding(6)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    if !node.transcript.isEmpty {
                        Section("Transcript") {
                            ForEach(node.transcript) { entry in
                                Text(entry.content)
                                    .font(.caption)
                                    .foregroundStyle(entry.role == .assistant ? Theme.primary : .secondary)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(entry.role == .assistant ? Theme.surface : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    if node.costUSD != nil || node.totalTokens != nil {
                        Divider()
                        HStack(spacing: 16) {
                            if let cost = node.costUSD {
                                Label(String(format: "$%.4f", cost), systemImage: "dollarsign.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let tokens = node.totalTokens {
                                Label("\(tokens) tokens", systemImage: "number.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(String(node.goal.prefix(40)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var nodeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: node.status.iconName)
                    .foregroundStyle(colorForStatus(node.status))
                Text(String(node.goal.prefix(80)))
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Label(node.status.rawValue, systemImage: node.status.iconName)
                    .font(.caption2)
                    .foregroundStyle(colorForStatus(node.status))
                Label(node.durationString, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let model = node.model {
                    Label(model, systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
