import SwiftUI

/// Drill-in view for a single session — shows spawn tree + usage tabs.
/// Presented as a sheet on long-press of a session row.
struct SessionExplorerView: View {
    let sessionID: String
    var runtimeSessionID: String?
    var onDismiss: (() -> Void)?
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var sessionList: SessionListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedNodeID: String?
    @State private var showTranscriptFor: SpawnNode?
    private let maxTreeDepth: Int = 32
    @State private var selectedTab: ExplorerTab = .tree

    // Usage data
    @State private var usage: SessionUsage?
    @State private var isLoadingUsage = false
    @State private var usageError: String?

    // Chat data
    @State private var chatMessages: [ChatMessage] = []
    @State private var isLoadingChat = false
    @State private var chatError: String?

    enum ExplorerTab: String, CaseIterable {
        case tree = "Agents"
        case chat = "Chat"
        case history = "History"
        case usage = "Usage"
    }

    private var session: Session? {
        sessionList.sessions.first(where: { $0.id == sessionID })
    }

    private var tree: SessionTree? {
        spawnTreeStore.sessions.first { $0.sessionID == sessionID }
    }

    private var rpcSessionID: String {
        runtimeSessionID?.isEmpty == false ? runtimeSessionID! : sessionID
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(ExplorerTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Content
                Group {
                    switch selectedTab {
                    case .tree:
                        treeOrEmpty
                    case .chat:
                        chatContent
                    case .history:
                        historyContent
                    case .usage:
                        usageContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onDismiss { onDismiss() } else { dismiss() }
                    }
                }
                if selectedTab == .tree, let tree {
                    ToolbarItem(placement: .primaryAction) {
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

    // MARK: - History Tab

    private var historyContent: some View {
        SessionRunTimelineView(events: SessionRunHistoryStore.shared.events(for: sessionID))
            .padding(16)
    }

    // MARK: - Chat Tab

    private var chatContent: some View {
        Group {
            if isLoadingChat {
                ProgressView("Loading conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = chatError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Cannot Load Chat")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if chatMessages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Messages")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("This session's conversation history is empty or unavailable.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(chatMessages) { message in
                            ChatHistoryMessageView(message: message)
                        }
                    }
                    .padding()
                }
            }
        }
        .task { await loadChat() }
    }

    private func loadChat() async {
        guard case .connected = gatewayClientWrapper.client.connectionState else {
            chatError = "Not connected to gateway"
            return
        }
        isLoadingChat = true
        chatError = nil
        do {
            let raw: [[String: AnyCodable]]
            if session?.isOwned == true {
                raw = try await gatewayClientWrapper.client.sessionHistory(sessionID: rpcSessionID)
            } else {
                // session.history requires a short hex runtime ID.  Non-owned
                // sessions only have the database key, so use peekSession which
                // resumes, fetches messages, and closes the session immediately.
                let peek = try await gatewayClientWrapper.client.peekSession(sessionKey: sessionID)
                raw = peek.messages
            }
            chatMessages = ChatViewModel.parseHistoryMessages(raw)
        } catch {
            chatError = error.localizedDescription
        }
        isLoadingChat = false
    }

    // MARK: - Tree Tab

    private var treeOrEmpty: some View {
        Group {
            if let tree {
                treeContent(tree: tree)
            } else {
                emptyTreeState
            }
        }
    }

    private func treeContent(tree: SessionTree) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                sessionMetadataCard

                // HUD
                sessionHUD(tree: tree)

                // Spawn tree
                TreeNodeView(
                    node: tree.root,
                    depth: 0,
                    maxDepth: maxTreeDepth,
                    selectedNodeID: $selectedNodeID,
                    onNodeTap: { node in
                        selectedNodeID = node.id
                        showTranscriptFor = node
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

    private var emptyTreeState: some View {
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

    // MARK: - Session Metadata Card

    @ViewBuilder
    private var sessionMetadataCard: some View {
        guard let session else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(sessionList.titleForSession(session))
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)
                    Spacer()
                    if session.isLive {
                        let state = session.displayRunState
                        Text(state.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.success.opacity(0.12), in: Capsule())
                    } else {
                        Text(session.status == .ended ? "Ended" : "Idle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 12) {
                    if let source = session.source, !source.isEmpty {
                        Label(source.capitalized, systemImage: sourceIcon(source))
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    if session.messageCount > 0 {
                        Label("\(session.messageCount) msgs", systemImage: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let startedAt = session.startedAt {
                        Label(startedAt.formatted(date: .abbreviated, time: .shortened),
                              systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let preview = session.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        )
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

                Label("\(max(0, tree.nodeCount - 1)) subagents", systemImage: "person.2.wave.2")
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
                try? await gatewayClientWrapper.client.interrupt(sessionID: rpcSessionID)
            }
        } label: {
            Label("Interrupt", systemImage: "stop.fill")
        }
        .disabled(!tree.isRunning)
    }

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "native", "hermes native": return "macbook.and.iphone"
        case "telegram": return "paperplane"
        case "discord": return "headphones"
        case "cli", "tui": return "terminal"
        case "cron": return "clock"
        case "web": return "globe"
        default: return "questionmark.circle"
        }
    }

    private func shortModel(_ model: String) -> String {
        let trimmed = model
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "openrouter/", with: "")
        return String(trimmed.prefix(20))
    }

    // MARK: - Usage Tab

    private var usageContent: some View {
        Group {
            if isLoadingUsage {
                ProgressView("Loading usage…")
            } else if let error = usageError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Cannot Load Usage")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else if let usage {
                ScrollView {
                    VStack(spacing: 16) {
                        explorerUsageDashboard(usage: usage)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Usage Data")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Usage is available only while the gateway can resolve the live runtime session.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task { await loadUsage() }
    }

    private func explorerUsageDashboard(usage: SessionUsage) -> some View {
        VStack(spacing: 16) {
            // Model
            usageCard(icon: "cpu", title: "Model", value: shortModel(usage.model))

            // Cost
            if let cost = usage.costUSD, cost > 0 {
                usageCard(icon: "dollarsign.circle", title: "Cost",
                          value: String(format: "$%.4f", cost))
            }

            // Tokens
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                usageCard(icon: "arrow.down.circle", title: "Input",
                          value: formatNumber(usage.inputTokens))
                usageCard(icon: "arrow.up.circle", title: "Output",
                          value: formatNumber(usage.outputTokens))
                usageCard(icon: "number.circle", title: "Total",
                          value: formatNumber(usage.totalTokens))
                usageCard(icon: "phone.connection", title: "API Calls",
                          value: formatNumber(usage.apiCalls))
            }

            // Cache stats
            if let cacheRead = usage.cacheReadTokens, cacheRead > 0 {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    usageCard(icon: "arrow.triangle.2.circlepath", title: "Cache Read",
                              value: formatNumber(cacheRead))
                    if let cacheWrite = usage.cacheWriteTokens, cacheWrite > 0 {
                        usageCard(icon: "arrow.triangle.circlepath", title: "Cache Write",
                                  value: formatNumber(cacheWrite))
                    }
                }
            }

            // Context window
            if let ctxPct = usage.contextPercent, let ctxUsed = usage.contextUsed, let ctxMax = usage.contextMax {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "text.append")
                            .foregroundStyle(Theme.accent)
                        Text("Context Window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formatNumber(ctxUsed)) / \(formatNumber(ctxMax))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ProgressView(value: Double(ctxPct) / 100.0)
                        .tint(ctxPct > 80 ? Theme.warning : Theme.accent)
                    Text("\(ctxPct)% used")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Compressions
            if let compressions = usage.compressions, compressions > 0 {
                usageCard(icon: "arrow.3.trianglepath", title: "Compressions",
                          value: "\(compressions)")
            }
        }
    }

    private func usageCard(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func loadUsage() async {
        guard case .connected = gatewayClientWrapper.client.connectionState else {
            usageError = "Not connected to gateway"
            return
        }
        isLoadingUsage = true
        usageError = nil
        do {
            usage = try await gatewayClientWrapper.client.sessionUsage(sessionID: rpcSessionID)
        } catch {
            if rpcSessionID != sessionID,
               let fallbackUsage = try? await gatewayClientWrapper.client.sessionUsage(sessionID: sessionID) {
                usage = fallbackUsage
                usageError = nil
            } else {
                usageError = error.localizedDescription
            }
        }
        isLoadingUsage = false
    }
}

// MARK: - Chat History Message View

private struct ChatHistoryMessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user {
                    Spacer(minLength: 60)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.caption)
                            .foregroundStyle(message.role == .user ? .white : Theme.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(message.toolCalls) { tool in
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(tool.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let summary = tool.summary {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(summary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(6)
                        .background(Theme.surface.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(10)
                .background(message.role == .user
                    ? Theme.accent
                    : Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if message.role == .assistant {
                    Spacer(minLength: 60)
                }
            }
        }
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
                            ForEach(node.readableTranscript) { entry in
                                transcriptEntryView(entry)
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

    private func transcriptEntryView(_ entry: NodeTranscriptEntry) -> some View {
        Text(entry.content)
            .font(.caption)
            .foregroundStyle(entry.role == .assistant ? Theme.primary : .secondary)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.role == .assistant ? Theme.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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