import SwiftUI

/// The Artifacts pane — first-class surface for living artifacts: every
/// named model (maps/charts/graphs/stats/tables/docs) any writer maintains,
/// rendered live. List on the left (kind icon, freshness, writer), detail
/// on the right with a Rendered/History tab switch. History shows the
/// revision audit trail with kind-aware diffs and one-click restore.
struct ArtifactsPane: View {
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ArtifactStore.shared
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    @State private var selectedID: String?

    private var selected: LivingArtifact? {
        selectedID.flatMap { store.artifacts[$0] } ?? store.sortedArtifacts.first
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.border)
                if store.artifacts.isEmpty {
                    emptyState
                } else {
                    HSplitViewCompat {
                        artifactList
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                        if let artifact = selected {
                            ArtifactDetailView(artifact: artifact)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text("Select an artifact")
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await store.pull() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Artifacts")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primary)
            Text("\(store.artifacts.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 6)
                .background(Theme.surfaceHover, in: Capsule())
            Spacer()
            Button {
                Task { await store.pull() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Resync from gateway")
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 26, height: 26)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 24))
                .foregroundStyle(Theme.tertiary)
            Text("No artifacts yet")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            Text("Ask the agent to create a living map, chart, or table with an id — or agents and scheduled jobs can create them via the artifact tool.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artifactList: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(store.sortedArtifacts) { artifact in
                    artifactRow(artifact)
                }
            }
            .padding(10)
        }
        .background(Theme.surface.opacity(0.4))
    }

    private func artifactRow(_ artifact: LivingArtifact) -> some View {
        let isSelected = artifact.id == selected?.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: Self.icon(for: artifact.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
                    .frame(width: 16)
                Text(artifact.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer()
                if artifact.rev > 0 {
                    Text("r\(artifact.rev)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            HStack(spacing: 5) {
                Text(artifact.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                if !artifact.updatedBy.isEmpty {
                    Text("· \(artifact.updatedBy)")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 23)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = artifact.id }
        .contextMenu {
            Button(role: .destructive) {
                store.remove(id: artifact.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "map": return "map"
        case "chart": return "chart.bar"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "gauge.medium"
        case "table", "dataset": return "tablecells"
        case "model": return "square.stack.3d.up"
        case "html": return "safari"
        default: return "doc.richtext"
        }
    }
}

/// HSplitView on macOS, HStack elsewhere.
private struct HSplitViewCompat<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        #if os(macOS)
        HSplitView { content }
        #else
        HStack(spacing: 0) { content }
        #endif
    }
}

// MARK: - Detail (Rendered / History)

private struct ArtifactDetailView: View {
    let artifact: LivingArtifact
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    private enum Tab: String, CaseIterable { case rendered = "Rendered", history = "History" }
    @State private var tab: Tab = .rendered
    @State private var cronVM = CronListViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                Text(artifact.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider().overlay(Theme.border.opacity(0.5))

            switch tab {
            case .rendered:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ArtifactMaintenanceSection(artifact: artifact, jobs: cronVM.jobs)
                        ArtifactKindRenderer(
                            kind: artifact.kind, content: artifact.content,
                            actionableArtifactID: artifact.id
                        )
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task {
                    cronVM.setGatewayClient(gatewayClientWrapper.client)
                    await cronVM.refreshJobs()
                }
            case .history:
                ArtifactHistoryView(artifact: artifact)
            }
        }
        // Tab resets when switching artifacts.
        .id(artifact.id)
    }
}

/// Render any artifact kind through the same block views chat uses.
struct ArtifactKindRenderer: View {
    let kind: String
    let content: String
    /// The artifact id when rendering the LIVE artifact (not a history
    /// revision) — enables declared per-entry actions on dataset/map.
    var actionableArtifactID: String?

    var body: some View {
        switch kind {
        case "map":
            MapBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "chart":
            NativeChartView(json: content, isStreaming: false, interactive: true)
        case "graph":
            NetworkGraphView(json: content, isStreaming: false)
        case "stats":
            StatTilesView(json: content, isStreaming: false)
        case "dataset":
            DatasetBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "timeline":
            TimelineBlockView(json: content, isStreaming: false)
        case "sankey":
            SankeyBlockView(json: content, isStreaming: false)
        case "model":
            ModelBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "html":
            // A self-contained HTML document — content is raw HTML, not JSON.
            // Renders in the same WKWebView-backed view chat uses for "Open
            // Page" on an html fence (JS on, ephemeral store, external links
            // open in the system browser).
            InlineHTMLView(html: content)
                .frame(minHeight: 320)
        default:
            MarkdownContentView(text: content, isStreaming: false)
                .equatable()
        }
    }
}

// MARK: - History

private struct ArtifactHistoryView: View {
    let artifact: LivingArtifact
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    @State private var revisions: [ArtifactRevision] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedRevision: ArtifactRevision?
    @State private var selectedContent: String?
    @State private var isRestoring = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 8) {
                    HermesProgressView()
                    Text("Loading history…")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 6) {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if revisions.isEmpty {
                Text("No revision history — this artifact hasn't synced to the gateway yet.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historySplit
            }
        }
        .task(id: artifact.id) { await load() }
    }

    private var historySplit: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(revisions) { revision in
                        revisionRow(revision)
                    }
                }
                .padding(10)
            }
            .frame(width: 230)
            .background(Theme.surface.opacity(0.4))
            Divider().overlay(Theme.border.opacity(0.5))
            revisionDetail
        }
    }

    private func revisionRow(_ revision: ArtifactRevision) -> some View {
        let isSelected = selectedRevision?.rev == revision.rev
        let isCurrent = revision.rev == artifact.rev
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("r\(revision.rev)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primary)
                if isCurrent {
                    Text("current")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            if let at = revision.updatedAt {
                Text(at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            if !revision.updatedBy.isEmpty {
                Text(revision.updatedBy)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRevision = revision
            Task { await loadRevisionContent(revision) }
        }
    }

    @ViewBuilder
    private var revisionDetail: some View {
        if let revision = selectedRevision {
            VStack(spacing: 0) {
                HStack {
                    Text("Revision \(revision.rev)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Spacer()
                    if revision.rev != artifact.rev {
                        Button(isRestoring ? "Restoring…" : "Restore this revision") {
                            Task { await restore(revision) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRestoring || selectedContent == nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider().overlay(Theme.border.opacity(0.4))
                if let content = selectedContent {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let diff = ArtifactDiff.describe(
                                kind: artifact.kind, old: content, new: artifact.content
                            ), revision.rev != artifact.rev {
                                diffSummary(diff)
                            }
                            ArtifactKindRenderer(kind: artifact.kind, content: content)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HermesProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Text("Select a revision to inspect")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffSummary(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Changes since this revision")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            ForEach(lines, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceHover.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            revisions = try await gatewayClientWrapper.client.artifactRevisions(id: artifact.id)
            selectedRevision = revisions.first
            if let first = revisions.first { await loadRevisionContent(first) }
        } catch {
            loadError = "Couldn't load history: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadRevisionContent(_ revision: ArtifactRevision) async {
        selectedContent = nil
        if revision.rev == artifact.rev {
            selectedContent = artifact.content
            return
        }
        let full = try? await gatewayClientWrapper.client.artifactRevision(
            id: artifact.id, rev: revision.rev
        )
        selectedContent = full?.content ?? ""
    }

    /// Restore = write the old content back as a NEW revision (history is
    /// never rewritten); replace skips the merge so the restore is exact.
    private func restore(_ revision: ArtifactRevision) async {
        guard let content = selectedContent else { return }
        isRestoring = true
        defer { isRestoring = false }
        _ = try? await gatewayClientWrapper.client.artifactSet(
            id: artifact.id, kind: artifact.kind, content: content,
            title: artifact.title.isEmpty ? nil : artifact.title, replace: true
        )
        await ArtifactStore.shared.pull()
        await load()
    }
}

// MARK: - Kind-aware diff

/// Human-readable change summary between two artifact bodies.
enum ArtifactDiff {

    /// nil = no summarizable difference (identical, or kind has no
    /// semantic differ and the caller should not show a summary).
    static func describe(kind: String, old: String, new: String) -> [String]? {
        guard old != new else { return nil }
        if kind == "map" {
            return describeMapDiff(old: old, new: new)
        }
        if kind == "dataset" {
            return describeDatasetDiff(old: old, new: new)
        }
        return ["Content changed (\(byteDelta(old: old, new: new)))"]
    }

    /// Marker-level diff: added / removed / changed-by-label.
    static func describeMapDiff(old: String, new: String) -> [String] {
        func markers(_ s: String) -> [String: [String: Any]] {
            guard let data = s.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let list = obj["markers"] as? [[String: Any]] else { return [:] }
            var byLabel: [String: [String: Any]] = [:]
            for marker in list {
                if let label = marker["label"] as? String { byLabel[label] = marker }
            }
            return byLabel
        }
        let oldMarkers = markers(old)
        let newMarkers = markers(new)
        var lines: [String] = []
        for label in newMarkers.keys.sorted() where oldMarkers[label] == nil {
            lines.append("Added \(label)")
        }
        for label in oldMarkers.keys.sorted() where newMarkers[label] == nil {
            lines.append("Removed \(label)")
        }
        for label in newMarkers.keys.sorted() {
            guard let before = oldMarkers[label], let after = newMarkers[label] else { continue }
            let beforeGroup = before["group"] as? String ?? ""
            let afterGroup = after["group"] as? String ?? ""
            let beforeNote = before["note"] as? String ?? ""
            let afterNote = after["note"] as? String ?? ""
            if beforeGroup != afterGroup {
                lines.append("\(label): \(beforeGroup.isEmpty ? "—" : beforeGroup) → \(afterGroup.isEmpty ? "—" : afterGroup)")
            } else if beforeNote != afterNote {
                lines.append("\(label): note updated")
            }
        }
        return lines.isEmpty ? ["Map metadata changed"] : lines
    }

    /// Row-level diff keyed by the dataset's key field.
    static func describeDatasetDiff(old: String, new: String) -> [String] {
        func rows(_ s: String) -> (key: String, byKey: [String: [String: Any]]) {
            guard let data = s.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let list = obj["rows"] as? [[String: Any]] else { return ("id", [:]) }
            let key = (obj["key"] as? String) ?? "id"
            var byKey: [String: [String: Any]] = [:]
            for row in list {
                let value = String(describing: row[key] ?? "")
                if !value.isEmpty && value != "nil" { byKey[value] = row }
            }
            return (key, byKey)
        }
        let (_, oldRows) = rows(old)
        let (_, newRows) = rows(new)
        var lines: [String] = []
        for key in newRows.keys.sorted() where oldRows[key] == nil {
            lines.append("Added \(key)")
        }
        for key in oldRows.keys.sorted() where newRows[key] == nil {
            lines.append("Removed \(key)")
        }
        for key in newRows.keys.sorted() {
            guard let before = oldRows[key], let after = newRows[key] else { continue }
            let changed = after.keys.filter { field in
                String(describing: before[field] ?? "") != String(describing: after[field] ?? "")
            }.sorted()
            if !changed.isEmpty {
                lines.append("\(key): \(changed.joined(separator: ", ")) changed")
            }
        }
        return lines.isEmpty ? ["Dataset metadata changed"] : lines
    }

    private static func byteDelta(old: String, new: String) -> String {
        let delta = new.count - old.count
        if delta == 0 { return "same size" }
        return delta > 0 ? "+\(delta) chars" : "\(delta) chars"
    }
}
