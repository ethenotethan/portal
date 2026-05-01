import SwiftUI

/// Drill-in view for a single session — shows the spawn tree as a node graph.
/// The root node is the user's prompt; children are subagents; grandchildren are their delegates.
struct SessionExplorerView: View {
    @ObservedObject var tree: SessionTree
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var selectedNodeID: String?
    @State private var showTranscriptFor: SpawnNode?
    @State private var expandDepth: Int = 2

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        // HUD bar
                        sessionHUD
                            .padding()

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
                        .padding(24)
                    }
                }
            }
            .navigationTitle(tree.root.goal.isEmpty ? "Session" : String(tree.root.goal.prefix(60)))
            #if os(macOS)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    depthControl
                    interruptButton
                }
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    depthControl
                    interruptButton
                }
            }
            #endif
            .sheet(item: $showTranscriptFor) { node in
                NodeTranscriptSheet(node: node)
            }
        }
    }

    // MARK: - HUD

    private var sessionHUD: some View {
        HStack(spacing: 16) {
            // Status
            Label {
                Text(tree.root.status.rawValue.capitalized)
            } icon: {
                Image(systemName: tree.root.status.iconName)
                    .foregroundStyle(colorForStatus(tree.root.status))
            }
            .font(.caption)

            Divider().frame(height: 16)

            // Node count
            Label("\(tree.nodeCount) nodes", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Running count
            if tree.isRunning {
                Label("\(tree.root.runningDescendantCount) active", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .modifier(PulseEffect())
            }

            Divider().frame(height: 16)

            // Cost
            if tree.totalCost > 0 {
                Label(String(format: "$%.4f", tree.totalCost), systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Duration
            Label(tree.root.durationString, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Model (if set on any node)
            if let model = tree.root.model ?? tree.root.allDescendants.first?.model {
                Text(model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Depth Control

    private var depthControl: some View {
        Stepper("Depth: \(expandDepth)", value: $expandDepth, in: 0...10)
            .font(.caption)
    }

    // MARK: - Interrupt

    private var interruptButton: some View {
        Button {
            Task {
                guard let client = gatewayClientWrapper.client as? GatewayClient,
                      case .connected = client.connectionState else { return }
                try? await client.interrupt(sessionID: tree.sessionID)
            }
        } label: {
            Label("Interrupt", systemImage: "stop.fill")
        }
        .disabled(!tree.isRunning)
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
                    // Node header
                    nodeHeader

                    Divider()

                    // Thinking
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

                    // Tool calls
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
                                        if let summary = tool.summary {
                                            Text(summary)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                        }
                                    }
                                }
                                .padding(6)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    // Transcript
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

                    // Cost / tokens
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
