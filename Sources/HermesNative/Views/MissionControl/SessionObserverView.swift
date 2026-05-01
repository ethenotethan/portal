import SwiftUI

/// Read-only observer view for sessions created by other transports (Telegram, TUI, etc.).
/// Shows conversation history, usage stats, spawn tree snapshots, and rollback checkpoints.
/// No chat input, no interrupt — just observation and introspection.
struct SessionObserverView: View {
    let sessionID: String
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var sessionTitle: String = ""
    @State private var usage: SessionUsage?
    @State private var spawnTreeEntries: [SpawnTreeEntry] = []
    @State private var selectedSnapshot: SpawnTreeSnapshot?
    @State private var historyMessages: [ObserverMessage] = []
    @State private var isLoading = true
    @State private var selectedTab: ObserverTab = .history

    enum ObserverTab: String, CaseIterable {
        case history = "History"
        case usage = "Usage"
        case agents = "Agents"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(ObserverTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Content
                Group {
                    switch selectedTab {
                    case .history:
                        historyContent
                    case .usage:
                        usageContent
                    case .agents:
                        agentsContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(sessionTitle.isEmpty ? "Session" : String(sessionTitle.prefix(40)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadSessionData() }
            .sheet(item: $selectedSnapshot) { snapshot in
                SpawnTreeSnapshotView(snapshot: snapshot)
            }
        }
    }

    // MARK: - History Tab

    private var historyContent: some View {
        Group {
            if isLoading {
                ProgressView("Loading history…")
            } else if historyMessages.isEmpty {
                emptyState(icon: "text.bubble", title: "No History", subtitle: "This session has no messages.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(historyMessages) { msg in
                                observerMessageRow(msg)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    private func observerMessageRow(_ msg: ObserverMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Role label
            Text(msg.role.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(msg.role == "user" ? Theme.accent : .secondary)

            // Content
            Text(msg.content)
                .font(.subheadline)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)

            // Tool name (if tool message)
            if let toolName = msg.toolName {
                HStack(spacing: 4) {
                    Image(systemName: "wrench")
                        .font(.caption2)
                    Text(toolName)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(msg.role == "user" ? Theme.accent.opacity(0.08) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Usage Tab

    private var usageContent: some View {
        Group {
            if isLoading {
                ProgressView("Loading usage…")
            } else if let usage {
                ScrollView {
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
                    .padding()
                }
            } else {
                emptyState(icon: "chart.bar", title: "No Usage Data",
                           subtitle: "This session may not be active in the gateway.")
            }
        }
    }

    private func usageCard(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.primary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Agents Tab

    private var agentsContent: some View {
        Group {
            if isLoading {
                ProgressView("Loading agent data…")
            } else if spawnTreeEntries.isEmpty {
                emptyState(icon: "arrow.triangle.branch", title: "No Spawn Trees",
                           subtitle: "No subagent snapshots saved for this session.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(spawnTreeEntries) { entry in
                            spawnTreeEntryRow(entry)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func spawnTreeEntryRow(_ entry: SpawnTreeEntry) -> some View {
        Button {
            Task { await loadSnapshot(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    if !entry.label.isEmpty {
                        Text(entry.label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.primary)
                    }
                    Text("\(entry.subagentCount) subagent\(entry.subagentCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let date = entry.finishedDate {
                        Text(date.relativeString)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
            .padding(12)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data Loading

    private func loadSessionData() async {
        guard case .connected = gatewayClientWrapper.client.connectionState else { return }
        isLoading = true

        async let historyTask = loadHistory()
        async let usageTask = loadUsage()
        async let treesTask = loadSpawnTrees()

        _ = await (historyTask, usageTask, treesTask)
        isLoading = false
    }

    private func loadHistory() async {
        do {
            let response = try await gatewayClientWrapper.client.sessionHistory(sessionID: sessionID)
            historyMessages = response.compactMap { d -> ObserverMessage? in
                guard let role = d["role"]?.stringValue, let content = d["content"]?.stringValue else { return nil }
                return ObserverMessage(
                    role: role,
                    content: String(content.prefix(2000)),
                    toolName: d["tool_name"]?.stringValue ?? d["name"]?.stringValue
                )
            }
            // Use first user message as title
            if let firstUser = historyMessages.first(where: { $0.role == "user" }) {
                sessionTitle = String(firstUser.content.prefix(80))
            }
        } catch {
            // History may fail if session not active
        }
    }

    private func loadUsage() async {
        do {
            usage = try await gatewayClientWrapper.client.sessionUsage(sessionID: sessionID)
        } catch {
            // Usage may fail if session not active
        }
    }

    private func loadSpawnTrees() async {
        do {
            spawnTreeEntries = try await gatewayClientWrapper.client.spawnTreeList(
                sessionID: sessionID, crossSession: false
            )
        } catch {
            // Spawn trees may not exist
        }
    }

    private func loadSnapshot(_ entry: SpawnTreeEntry) async {
        do {
            selectedSnapshot = try await gatewayClientWrapper.client.spawnTreeLoad(path: entry.path)
        } catch {
            // Handle error
        }
    }

    // MARK: - Helpers

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private func shortModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "openrouter/", with: "")
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Observer Message

struct ObserverMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    let toolName: String?
}

// MARK: - Spawn Tree Snapshot View (drill-in from Agents tab)

struct SpawnTreeSnapshotView: View {
    let snapshot: SpawnTreeSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Summary HUD
                    snapshotHUD

                    Divider()

                    // Subagent tree
                    ForEach(snapshot.subagents) { agent in
                        SubagentRecordView(record: agent, depth: 0)
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(snapshot.label.isEmpty ? "Spawn Tree" : String(snapshot.label.prefix(30)))
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

    private var snapshotHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("\(snapshot.subagents.count) subagents", systemImage: "arrow.triangle.branch")
                    .font(.subheadline)
                    .foregroundStyle(Theme.primary)
                Label(String(format: "%.1fs", snapshot.duration), systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Total cost across all subagents
            let totalCost = snapshot.subagents.compactMap { $0.costUSD }.reduce(0, +)
            if totalCost > 0 {
                Label(String(format: "$%.4f total", totalCost), systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let totalTokens = snapshot.subagents.compactMap { $0.totalTokens }.reduce(0, +)
            if totalTokens > 0 {
                Label("\(totalTokens) tokens", systemImage: "number.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Subagent Record View (recursive tree rendering)

struct SubagentRecordView: View {
    let record: SubagentRecord
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Depth indicator
                if depth > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.3))
                        .frame(width: 3, height: 24)
                }

                // Status icon
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(record.goal.prefix(80)))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let model = record.model {
                            Text(shortModel(model))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let cost = record.costUSD, cost > 0 {
                            Text(String(format: "$%.4f", cost))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let tokens = record.totalTokens {
                            Text("\(tokens) tok")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let dur = record.durationSeconds {
                            Text(String(format: "%.1fs", dur))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Tool call stats
                    if record.apiCalls ?? 0 > 0 {
                        Text("\(record.apiCalls!) API calls")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }

                    // Files touched
                    if !record.filesWritten.isEmpty {
                        Text("Wrote \(record.filesWritten.count) file\(record.filesWritten.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                }

                Spacer()
            }
            .padding(10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Children
            ForEach(record.children) { child in
                SubagentRecordView(record: child, depth: depth + 1)
                    .padding(.leading, 20)
            }
        }
    }

    private var statusIcon: String {
        switch record.status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "interrupted": "pause.circle.fill"
        case "running": "circle.fill"
        default: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case "completed": Theme.success
        case "failed": .red
        case "interrupted": .orange
        case "running": .blue
        default: .secondary
        }
    }

    private func shortModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "openrouter/", with: "")
    }
}
