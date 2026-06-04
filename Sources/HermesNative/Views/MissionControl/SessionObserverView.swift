import SwiftUI

/// Read-only observer view for sessions created by other transports (Telegram, TUI, etc.).
/// Shows conversation history, usage stats, spawn tree snapshots.
/// No chat input, no interrupt — just observation and introspection.
///
/// For sessions the app owns (gatewayID available), uses session.history/session.usage directly.
/// For other sessions, uses peekSession (resume→get data→close) which is expensive.
struct SessionObserverView: View {
    let session: Session
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var sessionTitle: String = ""
    @State private var usage: SessionUsage?
    @State private var spawnTreeEntries: [SpawnTreeEntry] = []
    @State private var selectedSnapshot: SpawnTreeSnapshot?
    @State private var historyMessages: [ObserverMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedTab: ObserverTab = .history
    @State private var showPlayback = false
    @State private var showPromptBreakdown = false

    enum ObserverTab: String, CaseIterable {
        case history = "History"
        case usage = "Usage"
        case agents = "Agents"
    }

    /// Whether this session is owned by the app (has gatewayID).
    private var isOwned: Bool { session.isOwned }

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
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            showPlayback = true
                        } label: {
                            Image(systemName: "play.rectangle")
                        }
                        .help("Playback")
                        Button {
                            showPromptBreakdown = true
                        } label: {
                            Image(systemName: "text.alignleft")
                        }
                        .help("Prompt Breakdown")
                    }
                }
            }
            .task { await loadSessionData() }
            .sheet(item: $selectedSnapshot) { snapshot in
                SpawnTreeSnapshotView(snapshot: snapshot)
            }
            .sheet(isPresented: $showPlayback) {
                SessionPlaybackView(sessionID: session.id)
                    .environmentObject(gatewayClientWrapper)
            }
            .sheet(isPresented: $showPromptBreakdown) {
                PromptBreakdownSheet(sessionID: session.id)
                    .environmentObject(gatewayClientWrapper)
            }
        }
    }

    // MARK: - History Tab

    private var historyContent: some View {
        Group {
            if isLoading {
                ProgressView("Loading history…")
            } else if let error = loadError {
                // Show error for Other Sessions that can't be loaded
                emptyState(icon: "exclamationmark.triangle", title: "Cannot Load History",
                           subtitle: error)
            } else if historyMessages.isEmpty {
                emptyState(icon: "text.bubble", title: "No History",
                           subtitle: "This session has no messages.")
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

            // Content (for tool messages, show context if available)
            let displayText = msg.role == "tool" ? (msg.toolContext ?? msg.content) : msg.content
            if !displayText.isEmpty {
                Text(displayText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
            }

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
            } else if let error = loadError {
                emptyState(icon: "exclamationmark.triangle", title: "Cannot Load Usage",
                           subtitle: error)
            } else if let usage {
                // For non-owned sessions with all-zero usage, show a note
                if !isOwned && usage.totalTokens == 0 && usage.apiCalls == 0 {
                    emptyState(icon: "chart.bar", title: "Usage Unavailable",
                               subtitle: "Usage tracking requires an active session. Historical usage is not available for observed sessions.")
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            usageDashboard(usage: usage)
                        }
                        .padding()
                    }
                }
            } else {
                emptyState(icon: "chart.bar", title: "No Usage Data",
                           subtitle: "This session may not be active in the gateway.")
            }
        }
    }

    private func usageDashboard(usage: SessionUsage) -> some View {
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
        loadError = nil

        if isOwned {
            // We have the gatewayID (short hex) — use direct RPCs
            await loadOwnedSessionData()
        } else {
            // Other session — use peekSession (expensive but works)
            await loadOtherSessionData()
        }

        // Spawn trees work for all sessions (uses database ID, reads from disk)
        await loadSpawnTrees()

        isLoading = false
    }

    /// Load data for a session we own (we have the gateway short hex ID).
    private func loadOwnedSessionData() async {
        let rpcID = session.rpcID  // gatewayID (short hex)
        async let usageTask = loadUsage(rpcID: rpcID)

        // Try session.history (lightweight, requires live short hex).
        // If the session ended and the gateway cleaned up the runtime,
        // the short hex may be stale -> 4001. Fall back to peekSession.
        do {
            let response = try await gatewayClientWrapper.client.sessionHistory(sessionID: rpcID)
            historyMessages = response.compactMap { d -> ObserverMessage? in
                guard let role = d["role"]?.stringValue else { return nil }
                let content = d["text"]?.stringValue ?? d["content"]?.stringValue ?? ""
                guard !content.isEmpty || role == "tool" else { return nil }
                return ObserverMessage(
                    role: role,
                    content: String(content.prefix(2000)),
                    toolName: d["name"]?.stringValue ?? d["tool_name"]?.stringValue,
                    toolContext: d["context"]?.stringValue.map { String($0.prefix(2000)) }
                )
            }
            if let firstUser = historyMessages.first(where: { $0.role == "user" }) {
                sessionTitle = String(firstUser.content.prefix(80))
            }
        } catch let error as GatewayError {
            if case .rpcError(let rpcErr) = error, rpcErr.code == 4001 {
                await loadOtherSessionData()
            } else {
                loadError = "History unavailable: \(error.localizedDescription)"
            }
        } catch {
            loadError = "History unavailable: \(error.localizedDescription)"
        }

        _ = await usageTask
    }

    /// Load data for a session from another transport using peekSession.
    /// This is expensive (creates a full agent) so use sparingly.
    private func loadOtherSessionData() async {
        do {
            let result = try await gatewayClientWrapper.client.peekSession(sessionKey: session.id)
            // Parse messages from the peek result
            // Gateway format: {"role": "user"|"assistant"|"system", "text": "..."} or {"role": "tool", "name": "...", "context": "..."}
            historyMessages = result.messages.compactMap { d -> ObserverMessage? in
                guard let role = d["role"]?.stringValue else { return nil }
                // Gateway uses "text" key for user/assistant/system messages
                let content = d["text"]?.stringValue ?? d["content"]?.stringValue ?? ""
                guard !content.isEmpty || role == "tool" else { return nil }
                return ObserverMessage(
                    role: role,
                    content: String(content.prefix(2000)),
                    toolName: d["name"]?.stringValue ?? d["tool_name"]?.stringValue,
                    toolContext: d["context"]?.stringValue.map { String($0.prefix(2000)) }
                )
            }
            usage = result.usage
            // Use first user message as title
            if let firstUser = historyMessages.first(where: { $0.role == "user" }) {
                sessionTitle = String(firstUser.content.prefix(80))
            }
        } catch let error as GatewayError {
            loadError = "Session not accessible: \(error.localizedDescription)"
        } catch {
            loadError = "Could not load session: \(error.localizedDescription)"
        }
    }

    private func loadHistory(rpcID: String) async {
        do {
            let response = try await gatewayClientWrapper.client.sessionHistory(sessionID: rpcID)
            // Gateway format: {"role": "user"|"assistant"|"system", "text": "..."} or {"role": "tool", "name": "...", "context": "..."}
            historyMessages = response.compactMap { d -> ObserverMessage? in
                guard let role = d["role"]?.stringValue else { return nil }
                let content = d["text"]?.stringValue ?? d["content"]?.stringValue ?? ""
                guard !content.isEmpty || role == "tool" else { return nil }
                return ObserverMessage(
                    role: role,
                    content: String(content.prefix(2000)),
                    toolName: d["name"]?.stringValue ?? d["tool_name"]?.stringValue,
                    toolContext: d["context"]?.stringValue.map { String($0.prefix(2000)) }
                )
            }
            // Use first user message as title
            if let firstUser = historyMessages.first(where: { $0.role == "user" }) {
                sessionTitle = String(firstUser.content.prefix(80))
            }
        } catch {
            loadError = "History unavailable: \(error.localizedDescription)"
        }
    }

    private func loadUsage(rpcID: String) async {
        do {
            usage = try await gatewayClientWrapper.client.sessionUsage(sessionID: rpcID)
        } catch {
            // Usage may fail if session not active
        }
    }

    private func loadSpawnTrees() async {
        do {
            spawnTreeEntries = try await gatewayClientWrapper.client.spawnTreeList(
                sessionID: session.id, crossSession: false
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
    let toolContext: String?  // Gateway sends "context" for tool messages
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
                    }
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private var statusIcon: String {
        switch record.status {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case "completed": return .green
        case "failed": return .red
        case "running": return Theme.accent
        default: return .secondary
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

// MARK: - Prompt Breakdown Sheet

/// Wrapper that loads the prompt breakdown from the gateway before presenting
/// the ``PromptBreakdownView``. Handles loading and error states.
struct PromptBreakdownSheet: View {
    let sessionID: String
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    @State private var breakdown: PromptBreakdown?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading prompt breakdown…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Cannot Load Prompt")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            } else if let breakdown {
                PromptBreakdownView(breakdown: breakdown)
            }
        }
        .task { await loadBreakdown() }
    }

    private func loadBreakdown() async {
        guard case .connected = gatewayClientWrapper.client.connectionState else {
            error = "Not connected to gateway."
            isLoading = false
            return
        }

        do {
            breakdown = try await gatewayClientWrapper.client.promptBreakdown(sessionID: sessionID)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
