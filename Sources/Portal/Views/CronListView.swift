import SwiftUI

struct CronListView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject internal var settings: SettingsViewModel
    @State private var cronViewModel = CronListViewModel()
    @StateObject private var filterState = CronFilterState()

    private var filteredJobs: [CronJob] {
        filterState.apply(to: cronViewModel.jobs)
    }

    private var grouping: CronCategoryGrouping {
        CronCategory.group(filteredJobs)
    }

    var body: some View {
        List {
            if cronViewModel.jobs.isEmpty && cronViewModel.isLoading {
                loadingState
                    .listRowBackground(Color.clear)
            } else if cronViewModel.jobs.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
            } else if filteredJobs.isEmpty {
                noMatchesState
                    .listRowBackground(Color.clear)
            } else if filterState.groupByCategory {
                CronCategoryTree(
                    filterState: filterState,
                    grouping: grouping,
                    jobRow: { job in AnyView(jobRow(job)) }
                )
            } else {
                ForEach(filteredJobs) { job in
                    jobRow(job)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !cronViewModel.jobs.isEmpty {
                CronSearchBar(filterState: filterState, jobs: cronViewModel.jobs)
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationDestination(for: CronJob.self) { job in
            CronJobDetailView(
                job: job,
                supportsRemoveAndEdit: cronViewModel.supportsRemoveAndEdit,
                supportsTrigger: cronViewModel.supportsTrigger,
                onPause: { Task { await cronViewModel.pauseJob(id: job.id) } },
                onResume: { Task { await cronViewModel.resumeJob(id: job.id) } },
                onTrigger: { Task { await cronViewModel.triggerJob(id: job.id) } },
                onRemove: { Task { await cronViewModel.removeJob(id: job.id) } },
                onUpdatePrompt: { newPrompt in
                    Task { await cronViewModel.updatePrompt(id: job.id, newPrompt: newPrompt) }
                }
            )
            .environmentObject(gatewayClientWrapper)
        }
        .navigationTitle("Cron Jobs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    CronDashboardView()
                        .environmentObject(gatewayClientWrapper)
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
            }
        }
        .refreshable {
            await cronViewModel.refreshJobs()
        }
        .onChange(of: filterState.searchText) { _, query in
            // A match inside a collapsed category would be invisible; reveal the
            // whole tree while a query is active.
            guard filterState.groupByCategory,
                  !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            filterState.expandAll(in: grouping)
        }
        .task(id: settings.focusedGateway?.id) {
            // A focused Standard backend is HTTP-only: route cron through its
            // dashboard API. Otherwise use the WebSocket Gateway as before.
            if let standard = settings.focusedGateway, standard.kind == .hermesStandard,
               let client = Self.standardClient(for: standard) {
                cronViewModel.setStandardClient(client)
            } else {
                cronViewModel.setGatewayClient(gatewayClientWrapper.client)
            }
            await cronViewModel.refreshJobs()
        }
    }

    /// One job row, identical in flat and grouped modes so navigation, context
    /// menu, and swipe actions never diverge between the two.
    @ViewBuilder
    private func jobRow(_ job: CronJob) -> some View {
        NavigationLink(value: job) {
            CronJobRow(job: job, showsCategoryPath: !filterState.groupByCategory)
        }
        .contextMenu {
            cronActions(for: job)
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            pauseResumeButton(for: job)
        }
        .swipeActions(edge: .trailing) {
            removeButton(for: job)
        }
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Cron Jobs")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Cron jobs will appear here when scheduled")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Matching Jobs")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("No cron jobs match the current search or filters")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Clear Filters") {
                filterState.searchText = ""
                filterState.filterStatus = .all
                filterState.timeWindow = .all
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            PortalProgressView().scaleEffect(0.7)
            Text("Loading cron jobs…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func cronActions(for job: CronJob) -> some View {
        if cronViewModel.supportsTrigger {
            Button {
                Task { await cronViewModel.triggerJob(id: job.id) }
            } label: {
                Label("Run now", systemImage: "play.circle")
            }
            Divider()
        }
        pauseResumeButton(for: job)
        // Standard's dashboard API has no remove-job endpoint; only the
        // WebSocket Gateway offers it.
        if cronViewModel.supportsRemoveAndEdit {
            Divider()
            removeButton(for: job)
        }
    }

    /// Build an upstream Hermes dashboard client for a focused Standard gateway,
    /// or nil if its URL/token is unusable. Reads route through this instead of
    /// the WebSocket Gateway (Standard is HTTP-only).
    private static func standardClient(for gateway: SavedGateway) -> HermesStandardClient? {
        guard let baseURL = URL(string: gateway.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        do {
            return try HermesStandardClient(baseURL: baseURL, sessionToken: gateway.apiKey)
        } catch {
            return nil
        }
    }

    @ViewBuilder
    private func pauseResumeButton(for job: CronJob) -> some View {
        if job.state == "paused" || !job.enabled {
            Button {
                Task { await cronViewModel.resumeJob(id: job.id) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            #if os(iOS)
            .tint(.green)
            #endif
        } else {
            Button {
                Task { await cronViewModel.pauseJob(id: job.id) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            #if os(iOS)
            .tint(.orange)
            #endif
        }
    }

    private func removeButton(for job: CronJob) -> some View {
        Button(role: .destructive) {
            Task { await cronViewModel.removeJob(id: job.id) }
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }
}

// MARK: - Cron Job Row

struct CronJobRow: View {
    let job: CronJob
    /// In flat mode the full `life/training/morning-run` name is the only place
    /// the category is visible, so it stays. Under the category tree the path is
    /// already the enclosing headers, so the row shows just the leaf title.
    internal var showsCategoryPath: Bool = true

    private var displayName: String {
        showsCategoryPath ? job.name : CronCategory.title(for: job)
    }

    var body: some View {
        HStack(spacing: 10) {
            statusDot
                .font(.caption)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if !job.schedule.isEmpty {
                        Text(job.schedule)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(scheduleBadgeColor.opacity(0.15))
                            .foregroundStyle(scheduleBadgeColor)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 4) {
                    if let lastRun = job.lastRunAt {
                        Text("Last: \(lastRun.relativeString)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let status = job.lastStatus {
                        Circle()
                            .fill(status == "ok" ? Theme.success : Color.red)
                            .frame(width: 6, height: 6)
                    }
                }

                if let nextRun = job.nextRunAt {
                    Text("Next: \(nextRun.relativeString)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let preview = job.promptPreview, !preview.isEmpty {
                    Text(preview.truncated(to: 60))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !job.enabled || job.state == "paused" {
                Text(job.state == "paused" ? "Paused" : "Disabled")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        if job.state == "paused" || !job.enabled {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
        } else if job.lastStatus == "error" {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if job.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(Theme.accent)
        }
    }

    private var scheduleBadgeColor: Color {
        job.enabled ? Theme.accent : .secondary
    }
}

// MARK: - Cron Job Detail

struct CronJobDetailView: View {
    let job: CronJob
    /// Standard's dashboard API has no remove-job or edit-prompt endpoint, so
    /// those affordances hide when the source is a Standard backend.
    internal var supportsRemoveAndEdit = true
    /// Standard-only one-shot "Run now"; the WebSocket Gateway has no trigger.
    internal var supportsTrigger = false
    let onPause: () -> Void
    let onResume: () -> Void
    internal var onTrigger: () -> Void = {}
    let onRemove: () -> Void
    let onUpdatePrompt: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runStore = CronRunHistoryStore.shared
    @State private var isPromptExpanded = false
    @State private var isEditingPrompt = false
    @State private var editedPrompt = ""
    @State private var selectedRecord: CronRunRecord?

    private var runRecords: [CronRunRecord] {
        runStore.records(for: job.id).reversed()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !runRecords.isEmpty {
                    statsStrip
                    healthBar
                }
                detailCard
                if !runRecords.isEmpty {
                    runHistoryCard
                }
                promptCard
                actionButtons
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.background)
        .navigationTitle(job.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Text(job.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Stats

    private var successRate: Double {
        runStore.successRate(for: job.id)
    }

    private var failureCount: Int {
        runRecords.filter { !$0.isOk }.count
    }

    private var averageIntervalLabel: String? {
        guard let interval = runStore.averageInterval(for: job.id), interval > 0 else { return nil }
        if interval < 90 { return String(format: "%.0fs", interval) }
        if interval < 5_400 { return String(format: "%.0fm", interval / 60) }
        if interval < 172_800 { return String(format: "%.1fh", interval / 3_600) }
        return String(format: "%.1fd", interval / 86_400)
    }

    private var statsStrip: some View {
        HStack(spacing: 10) {
            statTile(
                "Success",
                value: String(format: "%.0f%%", successRate),
                tint: successRate >= 80 ? Theme.success : (successRate >= 50 ? Theme.warning : .red)
            )
            statTile("Runs", value: "\(runRecords.count)", tint: Theme.accent)
            statTile(
                "Failures",
                value: "\(failureCount)",
                tint: failureCount == 0 ? Theme.success : .red
            )
            if let interval = averageIntervalLabel {
                statTile("Avg gap", value: interval, tint: Theme.secondary)
            }
        }
    }

    private func statTile(_ label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var healthBar: some View {
        Group {
            if runRecords.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Run health")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.tertiary)
                    HStack(spacing: 2) {
                        let recent = Array(runRecords.reversed().suffix(40))
                        ForEach(recent) { record in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(record.isOk ? Theme.success : Color.red)
                                .frame(height: 16)
                                .opacity(record.isOk ? 0.85 : 1)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var detailCard: some View {
        VStack(spacing: 0) {
            detailRow("Schedule", value: job.schedule.isEmpty ? "—" : job.schedule)
            detailRow("State", value: job.state)
            detailRow("Enabled", value: job.enabled ? "Yes" : "No")
            detailRow("Last run", value: job.lastRunAt?.relativeString ?? "Never")
            detailRow("Last status", value: job.lastStatus ?? "—")
            detailRow("Next run", value: job.nextRunAt?.relativeString ?? "—")
            detailRow("Deliver", value: job.deliver.isEmpty ? "—" : job.deliver)
            if let err = job.lastError, !err.isEmpty {
                errorDetailRow(err)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func errorDetailRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last error")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var runHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run History")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            ForEach(Array(runRecords.prefix(20))) { record in
                Button {
                    selectedRecord = record
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(record.isOk ? Theme.success : Color.red)
                            .frame(width: 8, height: 8)
                        Text(record.firedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.subheadline)
                            .foregroundStyle(Theme.primary)
                        Spacer()
                        Text(record.status.capitalized)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(record.isOk ? Theme.success : .red)
                        if record.duration != nil {
                            Text(record.durationLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        if !record.isOk {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    record.isOk ? Color.clear : Color.red.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .popover(item: $selectedRecord) { record in
            runDetailPopover(record: record)
        }
    }

    private func runDetailPopover(record: CronRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(record.isOk ? Theme.success : Color.red)
                    .frame(width: 10, height: 10)
                Text(record.firedAt, format: .dateTime.month().day().hour().minute().second())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            Divider()
            HStack {
                Text("Status").font(.caption).foregroundStyle(Theme.tertiary).frame(width: 70, alignment: .leading)
                Text(record.status.capitalized).font(.caption.monospacedDigit())
                    .foregroundStyle(record.isOk ? Theme.success : .red)
            }
            if record.duration != nil {
                HStack {
                    Text("Duration").font(.caption).foregroundStyle(Theme.tertiary).frame(width: 70, alignment: .leading)
                    Text(record.durationLabel).font(.caption.monospacedDigit()).foregroundStyle(Theme.primary)
                }
            }
            if !record.isOk {
                if let msg = record.errorMessage, !msg.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error").font(.caption.weight(.semibold)).foregroundStyle(.red)
                        ScrollView {
                            Text(msg)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                    .padding(8)
                    .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("No error detail recorded for this run.")
                        .font(.caption).foregroundStyle(.red.opacity(0.7))
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prompt")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()

                if supportsRemoveAndEdit && !isEditingPrompt {
                    Button {
                        editedPrompt = promptText
                        isEditingPrompt = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isPromptExpandable && !isEditingPrompt {
                    Button(isPromptExpanded ? "Collapse" : "Expand") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isPromptExpanded.toggle()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            if isEditingPrompt {
                promptEditor
            } else {
                promptDisplay
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var promptEditor: some View {
        VStack(spacing: 10) {
            TextEditor(text: $editedPrompt)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .frame(minHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Cancel") {
                    isEditingPrompt = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save") {
                    onUpdatePrompt(editedPrompt)
                    isEditingPrompt = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var promptDisplay: some View {
        VStack(alignment: .leading, spacing: 6) {
            if supportsRemoveAndEdit && job.isPromptTruncated {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    Text("Prompt may be truncated — edit to save the full version")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                    Button("Edit Now") {
                        editedPrompt = promptText
                        isEditingPrompt = true
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 2)
            }
            Text(promptText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var promptText: String {
        let text = job.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? job.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return text.isEmpty ? "No prompt available" : text
    }

    private var isPromptExpandable: Bool {
        promptText.count > 400 || promptText.contains("\n")
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if job.state == "paused" || !job.enabled {
                Button {
                    onResume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    onPause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }

            if supportsTrigger {
                Button {
                    onTrigger()
                } label: {
                    Label("Run now", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
            }

            if supportsRemoveAndEdit {
                Button(role: .destructive) {
                    onRemove()
                    dismiss()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if job.state == "paused" || !job.enabled {
            Image(systemName: "pause.circle")
                .foregroundStyle(.orange)
        } else if job.lastStatus == "error" {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if job.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(Theme.accent)
        }
    }
}

#Preview {
    NavigationStack {
        CronListView()
            .environmentObject(GatewayClientWrapper())
            .environmentObject(SettingsViewModel())
    }
}
