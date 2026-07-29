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
internal struct DelegationBatchPanel: View {
    @ObservedObject internal var store: SpawnTreeStore
    /// Display session id — resolves to the tree whose batches we show.
    internal let sessionID: String?

    private var tree: SessionTree? {
        guard let sessionID else { return store.activeTree }
        return store.sessions.first { $0.sessionID == sessionID } ?? store.activeTree
    }

    internal var body: some View {
        if let tree {
            DelegationBatchContent(root: tree.root)
        } else {
            PanelEmptyState(
                icon: "bolt.horizontal.circle",
                message: "No delegation activity in this session yet"
            )
        }
    }
}

/// Observes the tree's root so a newly-spawned batch member (appended to
/// `root.children`) re-renders the list. Splits out from the panel so the
/// `@ObservedObject` binds to a concrete node, not an optional.
private struct DelegationBatchContent: View {
    @ObservedObject internal var root: SpawnNode

    private var batches: [DelegationBatch] {
        // Newest first — the most recent wave is what you just watched fire.
        DelegationBatch.batches(in: root).reversed()
    }

    internal var body: some View {
        let batches = self.batches
        if batches.isEmpty {
            PanelEmptyState(
                icon: "bolt.horizontal.circle",
                message: "No delegation batches yet.\nParallel subagent waves will appear here."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(batches) { DelegationBatchRow(batch: $0) }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(node.goal.isEmpty ? "subagent \(node.taskIndex)" : node.goal)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                stat(node.status.rawValue, systemImage: node.status.iconName, tint: colorForStatus(node.status))
                stat(node.durationString, systemImage: "clock")
                if let model = node.model, !model.isEmpty { stat(model, systemImage: "cpu") }
            }

            if node.totalTokens != nil || node.costUSD != nil || node.apiCalls != nil {
                HStack(spacing: 10) {
                    if let t = node.totalTokens { stat("\(t) tok", systemImage: "number") }
                    if let cost = node.costUSD, cost > 0 { stat(String(format: "$%.4f", cost), systemImage: "dollarsign.circle") }
                    if let calls = node.apiCalls { stat("\(calls) calls", systemImage: "arrow.left.arrow.right") }
                }
            }

            if !node.toolCalls.isEmpty {
                detailRow(
                    label: "Tools",
                    value: node.toolCalls.map(\.name).joined(separator: ", ")
                )
            }
            if !node.filesWritten.isEmpty {
                detailRow(label: "Wrote", value: fileList(node.filesWritten))
            }
            if !node.filesRead.isEmpty {
                detailRow(label: "Read", value: fileList(node.filesRead))
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
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Show file basenames (paths get long); cap the list so a chatty subagent
    /// doesn't blow out the panel.
    private func fileList(_ paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(shown) +\(names.count - 6) more" : shown
    }
}
