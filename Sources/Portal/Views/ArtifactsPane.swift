import SwiftUI

/// The Artifacts pane — first-class surface for living artifacts: every
/// named model (maps/charts/graphs/stats/tables/docs) any writer maintains,
/// rendered live. List on the left (kind icon, freshness, writer), detail
/// on the right with a Rendered/History tab switch. History shows the
/// revision audit trail with kind-aware diffs and one-click restore.
struct ArtifactsPane: View {
    internal enum LayoutMode: Equatable {
        case drillDown
        case split
    }

    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var store = ArtifactStore.shared
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper

    @State private var selectedID: String?

    private var visibleArtifacts: [LivingArtifact] { store.sortedArtifacts }

    private var selected: LivingArtifact? {
        selectedID.flatMap { store.artifacts[$0] }.flatMap { a in
            visibleArtifacts.contains(where: { $0.id == a.id }) ? a : nil
        } ?? visibleArtifacts.first
    }

    /// iPhone-class widths cannot satisfy the desktop pane's 760-point split.
    /// Keep the split for regular widths and drill into a full-width detail on
    /// compact widths so renderers receive the actual viewport width.
    internal static func layoutMode(isCompactWidth: Bool) -> LayoutMode {
        isCompactWidth ? .drillDown : .split
    }

    internal var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.border)
                if visibleArtifacts.isEmpty {
                    emptyState
                } else if Self.layoutMode(isCompactWidth: horizontalSizeClass == .compact) == .drillDown {
                    compactContent
                } else {
                    splitContent
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 480)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .task { await store.pull() }
    }

    private var compactContent: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(visibleArtifacts) { artifact in
                        NavigationLink(value: artifact.id) {
                            artifactRowLabel(artifact, isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            deleteButton(for: artifact)
                        }
                    }
                }
                .padding(10)
            }
            .background(Theme.surface.opacity(0.4))
            .navigationDestination(for: String.self) { artifactID in
                if let artifact = store.artifacts[artifactID] {
                    ArtifactDetailView(artifact: artifact)
                        .navigationTitle(artifact.displayName)
                } else {
                    Text("This artifact is no longer available")
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var splitContent: some View {
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Artifacts")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primary)
            Text("\(visibleArtifacts.count)")
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
            .help("Resync from harness")
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
                ForEach(visibleArtifacts) { artifact in
                    artifactRow(artifact)
                }
            }
            .padding(10)
        }
        .background(Theme.surface.opacity(0.4))
    }

    private func artifactRow(_ artifact: LivingArtifact) -> some View {
        let isSelected = artifact.id == selected?.id
        return artifactRowLabel(artifact, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = artifact.id }
            .contextMenu {
                deleteButton(for: artifact)
            }
    }

    private func artifactRowLabel(_ artifact: LivingArtifact, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
                if let writer = WriterRef.parse(artifact.updatedBy) {
                    Text("· \(writer.label(cronName: { _ in nil }))")
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
    }

    private func deleteButton(for artifact: LivingArtifact) -> some View {
        Button(role: .destructive) {
            store.remove(id: artifact.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "map": return "map"
        case "chart": return "chart.bar"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "gauge.medium"
        case "table", "dataset": return "tablecells"
        case "checklist": return "checklist"
        case "kanban": return "rectangle.split.3x1"
        case "calendar": return "calendar"
        case "model": return "square.stack.3d.up"
        case "model3d": return "cube.transparent.fill"
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

/// Shared by the iOS pane and the macOS canvas's list mode — one detail
/// surface (Rendered / History) everywhere artifacts are inspected.
internal struct ArtifactDetailView: View {
    internal let artifact: LivingArtifact
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore

    private enum Tab: String, CaseIterable { case rendered = "Rendered", history = "History" }
    @State private var tab: Tab = .rendered
    @State private var cronVM = CronListViewModel()

    internal var body: some View {
        VStack(spacing: 0) {
            HStack {
                ThemedSegmentedControl(
                    selection: $tab,
                    options: Tab.allCases,
                    label: { $0.rawValue },
                    icon: { $0 == .rendered ? "doc.richtext" : "clock.arrow.circlepath" }
                )
                .frame(width: 210)
                Spacer()
                ArtifactExportMenu(artifact: artifact)
                if horizontalSizeClass != .compact {
                    Text(artifact.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider().overlay(Theme.border.opacity(0.5))

            switch tab {
            case .rendered:
                renderedTab
            case .history:
                ArtifactHistoryView(artifact: artifact, jobs: cronVM.jobs)
                    .task { await refreshCrons() }
            }
        }
        // Tab resets when switching artifacts.
        .id(artifact.id)
    }

    /// Kinds whose content manages its own scrolling/gestures (a WKWebView
    /// for html, the force-directed explorer for graph) — they must FILL the
    /// pane with a bounded height rather than sit in the outer ScrollView,
    /// where an unbounded height proposal collapses them.
    private var kindFillsHeight: Bool { ArtifactKindRenderer.kindFillsHeight(artifact.kind) }

    @ViewBuilder
    private var renderedTab: some View {
        if kindFillsHeight {
            // Maintenance pinned on top; the document fills the rest.
            VStack(alignment: .leading, spacing: 0) {
                ArtifactMaintenanceSection(artifact: artifact, jobs: cronVM.jobs)
                    .padding(16)
                ArtifactKindRenderer(
                    kind: artifact.kind, content: artifact.content,
                    actionableArtifactID: artifact.id,
                    topLevelActions: artifact.topLevelActions
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task { await refreshCrons() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ArtifactMaintenanceSection(artifact: artifact, jobs: cronVM.jobs)
                    ArtifactKindRenderer(
                        kind: artifact.kind, content: artifact.content,
                        actionableArtifactID: artifact.id,
                        topLevelActions: artifact.topLevelActions
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { await refreshCrons() }
        }
    }

    private func refreshCrons() async {
        cronVM.setGatewayClient(gatewayClientWrapper.client)
        await cronVM.refreshJobs()
        if capabilitiesStore.capabilities.supportsActionLog {
            ArtifactStore.shared.rehydrateBadges(for: artifact.id)
        }
    }
}

// MARK: - History

private struct ArtifactHistoryView: View {
    let artifact: LivingArtifact
    /// Known cron jobs — resolves a `cron:<jobId>` writer to its display name.
    var jobs: [CronJob] = []
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
                    PortalProgressView()
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
                        .portalButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if revisions.isEmpty {
                Text("No revision history — this artifact hasn't synced to the harness yet.")
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
            .frame(maxHeight: .infinity)
            .background(Theme.surface.opacity(0.4))
            Divider().overlay(Theme.border.opacity(0.5))
            revisionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let writer = WriterRef.parse(revision.updatedBy) {
                HStack(spacing: 4) {
                    Image(systemName: writer.icon)
                        .font(.system(size: 8))
                        .foregroundStyle(writerTint(writer))
                    Text(writer.label(cronName: cronName))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
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

    private func cronName(_ jobID: String) -> String? {
        jobs.first { $0.id == jobID }?.name
    }

    private func writerTint(_ writer: WriterRef) -> Color {
        switch writer {
        case .cron: return Theme.accent
        case .session: return Theme.secondary
        default: return Theme.tertiary
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
                        .portalButton(size: .small)
                        .disabled(isRestoring || selectedContent == nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider().overlay(Theme.border.opacity(0.4))
                if let content = selectedContent {
                    if ArtifactKindRenderer.kindFillsHeight(artifact.kind) {
                        // Full-document / interactive kinds fill and manage
                        // their own scrolling; a diff chip pins above them.
                        VStack(alignment: .leading, spacing: 0) {
                            if let diff = ArtifactDiff.describe(
                                kind: artifact.kind, old: content, new: artifact.content
                            ), revision.rev != artifact.rev {
                                diffSummary(diff).padding(14)
                            }
                            ArtifactKindRenderer(
                                kind: artifact.kind,
                                content: content,
                                suppressesPointerCapture: true
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if let diff = ArtifactDiff.describe(
                                    kind: artifact.kind, old: content, new: artifact.content
                                ), revision.rev != artifact.rev {
                                    diffSummary(diff)
                                }
                                ArtifactKindRenderer(
                                    kind: artifact.kind,
                                    content: content,
                                    suppressesPointerCapture: true
                                )
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    PortalProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
