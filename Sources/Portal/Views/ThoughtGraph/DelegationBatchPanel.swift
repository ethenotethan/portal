import SwiftUI

/// The Delegation Batches lens: every async wave of subagents this session
/// spawned, each rendered as a flamechart of concurrent subagent lanes. This is
/// the introspection surface behind the `[ASYNC DELEGATION BATCH COMPLETE]`
/// marker — the marker announces a batch finished; this shows what actually ran,
/// when, for how long, and at what cost.
///
/// Session-global and value-driven: it reads the session's `SpawnTreeStore` tree
/// and recomputes `DelegationBatch`es from it, so it persists across scroll/turn
/// paging. Liveness without a redraw timer of its own: it observes the tree's
/// root node (new batch members append to `root.children`), each lane observes
/// its own `SpawnNode` (status/cost/completion), and a scoped 1 Hz `TimelineView`
/// advances the growing right edge *only while a batch is still running*.
///
/// Also merges in **persisted** batches (`DelegationBatchHistoryStore`) so a
/// reopened past session — whose live in-memory tree is gone — still shows the
/// batches it ran. Live batches win over their persisted snapshot (same id), so
/// a batch that's currently running renders live, not as a stale record.
internal struct DelegationBatchPanel: View {
    @ObservedObject internal var store: SpawnTreeStore
    @ObservedObject internal var history: DelegationBatchHistoryStore
    /// Display session id — resolves to the tree/records whose batches we show.
    internal let sessionID: String?

    internal init(store: SpawnTreeStore, sessionID: String?) {
        self.store = store
        self.history = store.batchHistory
        self.sessionID = sessionID
    }

    private var tree: SessionTree? {
        guard let sessionID else { return store.activeTree }
        return store.sessions.first { $0.sessionID == sessionID } ?? store.activeTree
    }

    /// Persisted batches for this session, if we can name it.
    private var records: [DelegationBatchRecord] {
        guard let sessionID else { return [] }
        return history.records(for: sessionID)
    }

    internal var body: some View {
        DelegationBatchContent(root: tree?.root, records: records)
    }
}

/// Renders the merged batch list. Splits out from the panel so the live-tree
/// `@ObservedObject` can bind to a concrete `SpawnNode` (root) when present.
private struct DelegationBatchContent: View {
    /// The live tree's root, if this session is open in memory. Optional — a
    /// reopened past session has records but no live tree.
    private let root: SpawnNode?
    private let records: [DelegationBatchRecord]

    init(root: SpawnNode?, records: [DelegationBatchRecord]) {
        self.root = root
        self.records = records
    }

    var body: some View {
        if let root {
            LiveAndHistoryList(root: root, records: records)
        } else if records.isEmpty {
            emptyState
        } else {
            // No live tree — pure history (reopened past session).
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(records.reversed()) { DelegationRecordRow(record: $0) }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        PanelEmptyState(
            icon: "bolt.horizontal.circle",
            message: "No delegation batches yet.\nParallel subagent waves will appear here."
        )
    }
}

/// The live path: observes the tree root so new batch members re-render, and
/// folds in persisted records not represented by a live batch (id-deduped).
private struct LiveAndHistoryList: View {
    @ObservedObject var root: SpawnNode
    let records: [DelegationBatchRecord]

    var body: some View {
        let live = DelegationBatch.batches(in: root)
        let liveIDs = Set(live.map(\.id))
        // Records the live tree doesn't already cover (older waves this session
        // ran before, still on disk). Live wins on id.
        let extraRecords = records.filter { !liveIDs.contains($0.id) }

        if live.isEmpty && extraRecords.isEmpty {
            PanelEmptyState(
                icon: "bolt.horizontal.circle",
                message: "No delegation batches yet.\nParallel subagent waves will appear here."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Newest first: live waves lead, then older persisted ones.
                    ForEach(live.reversed()) { DelegationBatchRow(batch: $0) }
                    ForEach(extraRecords.reversed()) { DelegationRecordRow(record: $0) }
                }
                .padding(12)
            }
        }
    }
}

/// One batch: a header (status, member count, duration, cost/tokens) over a
/// stack of concurrent subagent lanes. While the batch is running, a scoped 1 Hz
/// clock advances the time axis so open lanes visibly grow.
private struct DelegationBatchRow: View {
    internal let batch: DelegationBatch
    /// The subagent whose detail is expanded inline below the lanes. Tapping a
    /// lane toggles it; nil = collapsed. Local to each batch row.
    @State private var selectedSubagentID: String?

    private var selectedNode: SpawnNode? {
        batch.subagents.first { $0.id == selectedSubagentID }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if batch.isRunning {
                // Only running batches tick — a finished batch is static, so the
                // panel costs a timer only while there is live work to show.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    lanes(asOf: context.date)
                }
            } else {
                lanes(asOf: batch.endedAt ?? batch.startedAt)
            }
            if let node = selectedNode {
                DelegationSubagentDetail(node: node)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: batch.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .font(.system(size: 13))
                .foregroundStyle(colorForStatus(batch.status))
                .symbolEffect(.pulse, options: .repeating, isActive: batch.isRunning)

            Text("\(batch.subagents.count) subagent\(batch.subagents.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)

            // Mid-flight the reported width can exceed the members seen so far.
            if batch.taskCount > batch.subagents.count {
                Text("of \(batch.taskCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 6)

            metric(durationLabel)
            if batch.totalTokens > 0 { metric(tokenLabel) }
            if batch.totalCost > 0 { metric(String(format: "$%.3f", batch.totalCost)) }
        }
    }

    /// Header duration: the settled span for a finished batch. Running batches
    /// show "running" rather than a frozen number — the live growth is carried by
    /// the lanes' 1 Hz tick, so a static count here would just look stale.
    private var durationLabel: String {
        guard let endedAt = batch.endedAt else { return "running" }
        return format(endedAt.timeIntervalSince(batch.startedAt))
    }

    private func metric(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.tertiary)
    }

    /// The concurrent-lane flamechart, laid out against `now` (the batch end for
    /// a finished batch, the live clock while running).
    private func lanes(asOf now: Date) -> some View {
        let span = max(batch.duration(asOf: now), 0.001)
        return VStack(spacing: 4) {
            ForEach(batch.subagents) { node in
                DelegationLaneView(
                    node: node,
                    batchStart: batch.startedAt,
                    span: span,
                    now: now,
                    isSelected: node.id == selectedSubagentID
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedSubagentID = selectedSubagentID == node.id ? nil : node.id
                    }
                }
            }
        }
    }

    private var tokenLabel: String {
        let t = batch.totalTokens
        return t >= 1000 ? String(format: "%.1fk tok", Double(t) / 1000) : "\(t) tok"
    }

    private func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        if seconds < 3600 { return String(format: "%.1fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }
}

/// A single subagent's lane: a bar offset by its start and sized by its runtime,
/// with the goal overlaid. Observes its own node so status/duration/cost updates
/// redraw just this lane. Tapping it toggles the batch's inline detail.
private struct DelegationLaneView: View {
    @ObservedObject internal var node: SpawnNode
    internal let batchStart: Date
    internal let span: TimeInterval
    internal let now: Date
    internal let isSelected: Bool
    internal let onTap: () -> Void

    internal var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.status.iconName)
                .font(.system(size: 9))
                .foregroundStyle(colorForStatus(node.status))
                .frame(width: 12)
                .symbolEffect(.pulse, options: .repeating, isActive: node.status.isRunning)

            GeometryReader { geo in
                let start = max(0, node.createdAt.timeIntervalSince(batchStart))
                let end = (node.completedAt ?? now).timeIntervalSince(batchStart)
                let x = geo.size.width * (start / span)
                let w = max(4, geo.size.width * ((end - start) / span))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Theme.accent.opacity(0.12) : Theme.surface)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colorForStatus(node.status).opacity(node.status.isRunning ? 0.35 : 0.5))
                        .frame(width: w)
                        .offset(x: x)
                    Text(node.goal.isEmpty ? "subagent \(node.taskIndex)" : node.goal)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 6)
                        .padding(.trailing, 4)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.accent, lineWidth: isSelected ? 1 : 0)
                )
            }
            .frame(height: 20)

            Text(node.durationString)
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Inline detail for the tapped subagent lane: its full goal, status/timing, and
/// what it did — token/cost accounting, the tools it called, and the files it
/// read or wrote. Observes the node so a still-running subagent's detail fills in
/// live. This is the "click into a batch and introspect its runtime" surface.
private struct DelegationSubagentDetail: View {
    @ObservedObject internal var node: SpawnNode

    internal var body: some View {
        DelegationDetailContent(
            title: node.goal.isEmpty ? "subagent \(node.taskIndex)" : node.goal,
            statusLabel: node.status.rawValue,
            statusIcon: node.status.iconName,
            statusTint: colorForStatus(node.status),
            durationLabel: node.durationString,
            model: node.model,
            totalTokens: node.totalTokens,
            costUSD: node.costUSD,
            apiCalls: node.apiCalls,
            toolNames: node.toolCalls.map(\.name),
            filesRead: node.filesRead,
            filesWritten: node.filesWritten
        )
    }
}

/// Value-driven subagent detail shared by the live lane and the persisted record
/// row — same layout, fed either from a `SpawnNode` (live) or a
/// `DelegationSubagentRecord` (history).
private struct DelegationDetailContent: View {
    internal let title: String
    internal let statusLabel: String
    internal let statusIcon: String
    internal let statusTint: Color
    internal let durationLabel: String
    internal let model: String?
    internal let totalTokens: Int?
    internal let costUSD: Double?
    internal let apiCalls: Int?
    internal let toolNames: [String]
    internal let filesRead: [String]
    internal let filesWritten: [String]

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                stat(statusLabel, systemImage: statusIcon, tint: statusTint)
                stat(durationLabel, systemImage: "clock")
                if let model, !model.isEmpty { stat(model, systemImage: "cpu") }
            }

            if totalTokens != nil || costUSD != nil || apiCalls != nil {
                HStack(spacing: 10) {
                    if let t = totalTokens { stat("\(t) tok", systemImage: "number") }
                    if let cost = costUSD, cost > 0 { stat(String(format: "$%.4f", cost), systemImage: "dollarsign.circle") }
                    if let calls = apiCalls { stat("\(calls) calls", systemImage: "arrow.left.arrow.right") }
                }
            }

            if !toolNames.isEmpty {
                detailRow(label: "Tools", value: toolNames.joined(separator: ", "))
            }
            if !filesWritten.isEmpty {
                detailRow(label: "Wrote", value: Self.fileList(filesWritten))
            }
            if !filesRead.isEmpty {
                detailRow(label: "Read", value: Self.fileList(filesRead))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ text: String, systemImage: String, tint: Color = Theme.tertiary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Show file basenames (paths get long); cap the list so a chatty subagent
    /// doesn't blow out the panel.
    internal static func fileList(_ paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(shown) +\(names.count - 6) more" : shown
    }
}

/// A persisted batch rendered from its `DelegationBatchRecord` — the static
/// counterpart to `DelegationBatchRow` for a reopened past session. Same header
/// and lane-detail visual language; no live tick (a record is settled) and lanes
/// are drawn from the flat snapshot.
private struct DelegationRecordRow: View {
    internal let record: DelegationBatchRecord
    @State private var selectedSubagentID: String?

    private var selected: DelegationSubagentRecord? {
        record.subagents.first { $0.id == selectedSubagentID }
    }

    private var span: TimeInterval {
        max(record.duration, 0.001)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 4) {
                ForEach(record.subagents) { sub in
                    lane(sub)
                }
            }
            if let sub = selected {
                DelegationDetailContent(
                    title: sub.goal.isEmpty ? "subagent \(sub.taskIndex)" : sub.goal,
                    statusLabel: sub.status,
                    statusIcon: statusIcon(sub.status),
                    statusTint: statusTint(sub.status),
                    durationLabel: format(sub.duration),
                    model: sub.model,
                    totalTokens: sub.totalTokens,
                    costUSD: sub.costUSD,
                    apiCalls: sub.apiCalls,
                    toolNames: sub.toolNames,
                    filesRead: sub.filesRead,
                    filesWritten: sub.filesWritten
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 13))
                .foregroundStyle(statusTint(record.status))
            Text("\(record.subagents.count) subagent\(record.subagents.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 6)
            metric(record.durationLabel)
            if record.totalTokens > 0 {
                metric(record.totalTokens >= 1000
                       ? String(format: "%.1fk tok", Double(record.totalTokens) / 1000)
                       : "\(record.totalTokens) tok")
            }
            if record.totalCost > 0 { metric(String(format: "$%.3f", record.totalCost)) }
        }
    }

    private func lane(_ sub: DelegationSubagentRecord) -> some View {
        let isSelected = sub.id == selectedSubagentID
        return HStack(spacing: 6) {
            Image(systemName: statusIcon(sub.status))
                .font(.system(size: 9))
                .foregroundStyle(statusTint(sub.status))
                .frame(width: 12)

            GeometryReader { geo in
                let start = max(0, sub.startedAt.timeIntervalSince(record.startedAt))
                let end = (sub.completedAt ?? record.endedAt ?? record.startedAt)
                    .timeIntervalSince(record.startedAt)
                let x = geo.size.width * (start / span)
                let w = max(4, geo.size.width * ((end - start) / span))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Theme.accent.opacity(0.12) : Theme.surface)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(statusTint(sub.status).opacity(0.5))
                        .frame(width: w)
                        .offset(x: x)
                    Text(sub.goal.isEmpty ? "subagent \(sub.taskIndex)" : sub.goal)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 6)
                        .padding(.trailing, 4)
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: isSelected ? 1 : 0))
            }
            .frame(height: 20)

            Text(format(sub.duration))
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedSubagentID = isSelected ? nil : sub.id
            }
        }
    }

    private func metric(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.tertiary)
    }

    private func statusTint(_ raw: String) -> Color {
        colorForStatus(NodeStatus(rawValue: raw) ?? .completed)
    }

    private func statusIcon(_ raw: String) -> String {
        (NodeStatus(rawValue: raw) ?? .completed).iconName
    }

    private func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        if seconds < 3600 { return String(format: "%.1fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }
}
