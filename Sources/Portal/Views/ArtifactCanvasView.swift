#if os(macOS)
import SwiftUI

/// Artifacts surface — switchable between a free-form canvas (one resizable
/// panel per artifact) and a classic list+detail split. The canvas opens in
/// edit mode so panels are immediately draggable; Done locks them so scroll/
/// click interactions work inside each panel.
@MainActor
internal struct ArtifactCanvasView: View {
    var onClose: (() -> Void)?

    @ObservedObject private var store = ArtifactStore.shared

    // Canvas state
    @State private var layout = DashboardLayout()
    @State private var didSeedLayout = false
    @State private var canvasBounds: CGSize = .zero
    @State private var isEditing = false
    @State private var showsTitleBars = true

    // List state
    @State private var selectedID: String?

    // Shared
    @AppStorage("artifactViewMode") private var viewMode: ViewMode = .list

    private enum ViewMode: String { case canvas, list }
    private static let layoutKey = "artifactCanvasLayout.v1"

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if store.sortedArtifacts.isEmpty {
                emptyState
            } else {
                switch viewMode {
                case .canvas: canvasBody
                case .list:   listBody
                }
            }
        }
        .background(Theme.background)
        .frame(minWidth: 700, minHeight: 480)
        .task { await store.pull() }
        .onChange(of: store.sortedArtifacts.map(\.id)) { _, newIDs in
            reconcileLayout(artifactIDs: newIDs, bounds: canvasBounds)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Artifacts")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primary)
            Text("\(store.sortedArtifacts.count)")
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

            // View mode toggle
            HStack(spacing: 2) {
                ForEach([ViewMode.list, .canvas], id: \.rawValue) { mode in
                    Button {
                        viewMode = mode
                    } label: {
                        Image(systemName: mode == .list ? "list.bullet" : "rectangle.3.group")
                            .font(.system(size: 11))
                            .foregroundStyle(viewMode == mode ? Theme.accent : Theme.tertiary)
                            .frame(width: 24, height: 24)
                            .background(
                                viewMode == mode ? Theme.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(mode == .list ? "List view" : "Canvas view")
                }
            }

            if viewMode == .canvas {
                Divider().frame(height: 16).opacity(0.4)

                // Add panel picker — only when panels have been hidden
                if !hiddenArtifacts.isEmpty {
                    Menu {
                        ForEach(hiddenArtifacts) { artifact in
                            Button {
                                addPanel(for: artifact)
                            } label: {
                                Label(artifact.displayName, systemImage: kindIcon(for: artifact.kind))
                            }
                        }
                    } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a hidden artifact panel back to the canvas")
                }

                Toggle(isOn: $showsTitleBars) {
                    Image(systemName: showsTitleBars ? "rectangle.topthird.inset.filled" : "rectangle")
                        .font(.system(size: 11))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(showsTitleBars ? Theme.accent : Theme.tertiary)
                .help(showsTitleBars ? "Hide panel headers" : "Show panel headers")

                Button(isEditing ? "Done" : "Edit") {
                    isEditing.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isEditing ? Theme.accent : nil)
                .help(isEditing ? "Lock layout — enable scroll/click inside panels" : "Edit layout — drag and resize panels")
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 26, height: 26)
                        .background(Theme.surfaceHover, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Canvas body

    private var canvasBody: some View {
        GeometryReader { geo in
            DashboardCanvasView(
                layout: $layout,
                isEditing: isEditing,
                showsTitleBars: showsTitleBars,
                title: { panelTitle(for: $0) },
                icon: { panelIcon(for: $0) },
                onLayoutCommitted: { layout.store(key: Self.layoutKey) },
                content: { panel in AnyView(panelContent(panel)) }
            )
            .onAppear {
                canvasBounds = geo.size
                seedLayoutIfNeeded(bounds: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                canvasBounds = newSize
                seedLayoutIfNeeded(bounds: newSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List body

    private var listBody: some View {
        HSplitView {
            // Sidebar — compact artifact list
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.sortedArtifacts) { artifact in
                        listRow(artifact)
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .background(Theme.surface.opacity(0.4))

            // Detail — full renderer for selected artifact
            if let artifact = selectedArtifact {
                ArtifactListDetail(artifact: artifact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(artifact.id)
            } else {
                Text("Select an artifact")
                    .font(.callout)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedID == nil { selectedID = store.sortedArtifacts.first?.id }
        }
    }

    private var selectedArtifact: LivingArtifact? {
        selectedID.flatMap { store.artifacts[$0] }
            ?? store.sortedArtifacts.first
    }

    private func listRow(_ artifact: LivingArtifact) -> some View {
        let isSelected = artifact.id == selectedArtifact?.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: kindIcon(for: artifact.kind))
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
                if !artifact.maintainerRefs.isEmpty {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.accent)
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 28))
                .foregroundStyle(Theme.tertiary)
            Text("No artifacts yet")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            Text("Ask the agent to create a living map, chart, or dataset with an id — or cron jobs can maintain them automatically.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Panel content

    @ViewBuilder
    private func panelContent(_ panel: DashboardPanel) -> some View {
        let artifactID = Self.artifactID(from: panel.kind)
        if let artifact = artifactID.flatMap({ store.artifacts[$0] }) {
            ArtifactPanelContent(artifact: artifact)
        } else {
            PanelEmptyState(icon: "exclamationmark.triangle", message: "Artifact not found")
        }
    }

    // MARK: - Panel kind ↔ artifact id

    /// `PanelKind` encoding: "artifact:<artifactID>".
    private static func kind(for artifactID: String) -> PanelKind {
        PanelKind(rawValue: "artifact:\(artifactID)")
    }

    private static func artifactID(from kind: PanelKind) -> String? {
        let raw = kind.rawValue
        guard raw.hasPrefix("artifact:") else { return nil }
        return String(raw.dropFirst("artifact:".count))
    }

    private func panelTitle(for kind: PanelKind) -> String {
        guard let id = Self.artifactID(from: kind),
              let artifact = store.artifacts[id] else { return "Artifact" }
        return artifact.displayName
    }

    private func panelIcon(for kind: PanelKind) -> String {
        guard let id = Self.artifactID(from: kind),
              let artifact = store.artifacts[id] else { return "internaldrive" }
        return kindIcon(for: artifact.kind)
    }

    private func kindIcon(for artifactKind: String) -> String {
        switch artifactKind {
        case "map": return "map"
        case "chart": return "chart.xyaxis.line"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "square.grid.2x2"
        case "dataset": return "tablecells"
        case "timeline": return "calendar.day.timeline.left"
        case "sankey": return "arrow.triangle.branch"
        case "model": return "cube.transparent"
        case "html": return "globe"
        default: return "doc.text"
        }
    }

    // MARK: - Layout management

    /// Artifacts currently on the canvas (have a panel).
    private var visibleArtifactIDs: Set<String> {
        Set(layout.panels.compactMap { Self.artifactID(from: $0.kind) })
    }

    /// Artifacts NOT on the canvas (removed by the user or newly added to the
    /// store after the canvas was seeded).
    private var hiddenArtifacts: [LivingArtifact] {
        store.sortedArtifacts.filter { !visibleArtifactIDs.contains($0.id) }
    }

    private func seedLayoutIfNeeded(bounds: CGSize) {
        guard !didSeedLayout, bounds.width > 0, bounds.height > 0 else { return }
        didSeedLayout = true
        if let stored = DashboardLayout.loadStored(key: Self.layoutKey) {
            // Prune panels for artifacts that no longer exist.
            let validIDs = Set(store.artifacts.keys)
            let pruned = DashboardLayout(panels: stored.panels.filter { panel in
                guard let id = Self.artifactID(from: panel.kind) else { return false }
                return validIDs.contains(id)
            })
            layout = pruned.isEmpty
                ? Self.seededDefault(for: bounds, artifacts: store.sortedArtifacts)
                : pruned.reflowed(from: bounds, to: bounds)
        } else {
            layout = Self.seededDefault(for: bounds, artifacts: store.sortedArtifacts)
        }
    }

    /// When artifacts are added or removed from the store, reconcile the canvas:
    /// prune stale panels, add new artifacts that have no panel yet.
    private func reconcileLayout(artifactIDs: [String], bounds: CGSize) {
        guard didSeedLayout, bounds.width > 0 else { return }
        let validSet = Set(artifactIDs)
        var panels = layout.panels.filter { panel in
            guard let id = Self.artifactID(from: panel.kind) else { return false }
            return validSet.contains(id)
        }
        let existing = Set(panels.compactMap { Self.artifactID(from: $0.kind) })
        let newIDs = artifactIDs.filter { !existing.contains($0) }
        for id in newIDs {
            let frame = Self.nextFrame(for: panels, bounds: bounds)
            panels.append(DashboardPanel(kind: Self.kind(for: id), frame: frame))
        }
        layout = DashboardLayout(panels: panels)
        layout.store(key: Self.layoutKey)
    }

    private func addPanel(for artifact: LivingArtifact) {
        let frame = Self.nextFrame(for: layout.panels, bounds: canvasBounds)
        layout.panels.append(DashboardPanel(kind: Self.kind(for: artifact.id), frame: frame))
        layout.store(key: Self.layoutKey)
    }

    /// Tile artifacts across the canvas. Fills left-to-right in rows of equal
    /// height, with a gap between panels.
    private static func seededDefault(for bounds: CGSize, artifacts: [LivingArtifact]) -> DashboardLayout {
        guard !artifacts.isEmpty else { return DashboardLayout() }
        let w = max(bounds.width, DashboardPanel.minSize.width)
        let h = max(bounds.height, DashboardPanel.minSize.height)
        let gap: CGFloat = 8
        let cols = max(1, Int(w / (DashboardPanel.minSize.width + gap)))
        let panelW = (w - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let rows = Int(ceil(Double(artifacts.count) / Double(cols)))
        let panelH = max(DashboardPanel.minSize.height, (h - gap * CGFloat(rows + 1)) / CGFloat(rows))
        var panels: [DashboardPanel] = []
        for (i, artifact) in artifacts.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = gap + CGFloat(col) * (panelW + gap)
            let y = gap + CGFloat(row) * (panelH + gap)
            panels.append(DashboardPanel(
                kind: Self.kind(for: artifact.id),
                frame: CGRect(x: x, y: y, width: panelW, height: panelH)
            ))
        }
        return DashboardLayout(panels: panels).clamped(to: bounds)
    }

    /// Pick a frame for a newly added panel: cascade from the top-left with a
    /// 24pt offset per existing panel, wrapping to avoid overflowing the canvas.
    private static func nextFrame(for existing: [DashboardPanel], bounds: CGSize) -> CGRect {
        let w = max(DashboardPanel.minSize.width, min(400, bounds.width * 0.4))
        let h = max(DashboardPanel.minSize.height, min(500, bounds.height * 0.6))
        let gap: CGFloat = 24
        let offset = CGFloat(existing.count % 6) * gap
        let x = min(offset, max(0, bounds.width - w - 8))
        let y = min(offset, max(0, bounds.height - h - 8))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - List detail view

/// Full-size detail pane used in list mode: maintenance section on top,
/// rendered content below.
private struct ArtifactListDetail: View {
    let artifact: LivingArtifact

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore

    @State private var cronVM = CronListViewModel()

    var body: some View {
        Group {
            if artifact.kind == "html" {
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
            }
        }
        .task { await refreshCrons() }
    }

    private func refreshCrons() async {
        cronVM.setGatewayClient(gatewayClientWrapper.client)
        await cronVM.refreshJobs()
        if capabilitiesStore.capabilities.supportsActionLog {
            ArtifactStore.shared.rehydrateBadges(for: artifact.id)
        }
    }
}

// MARK: - Per-artifact panel content

/// Renders a single artifact's content inside a canvas panel, with a compact
/// mini-header (kind pill + last-updated) above the live `ArtifactKindRenderer`.
/// The mini-header is separate from the panel's title bar chrome — it gives the
/// user extra context (when it was last touched, what kind it is) at a glance.
private struct ArtifactPanelContent: View {
    let artifact: LivingArtifact

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @ObservedObject private var store = ArtifactStore.shared
    @State private var cronVM = CronListViewModel()

    var body: some View {
        VStack(spacing: 0) {
            miniHeader
            Divider().overlay(Theme.border.opacity(0.4))
            // Kinds that fill height (html) need maxHeight; others scroll.
            if artifact.kind == "html" {
                ArtifactKindRenderer(
                    kind: artifact.kind,
                    content: store.artifacts[artifact.id]?.content ?? artifact.content,
                    actionableArtifactID: artifact.id,
                    topLevelActions: artifact.topLevelActions
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ArtifactKindRenderer(
                        kind: artifact.kind,
                        content: store.artifacts[artifact.id]?.content ?? artifact.content,
                        actionableArtifactID: artifact.id,
                        topLevelActions: artifact.topLevelActions
                    )
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await refreshCrons() }
    }

    private var miniHeader: some View {
        HStack(spacing: 6) {
            Text(artifact.kind)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accent.opacity(0.12), in: Capsule())

            if artifact.rev > 0 {
                Text("r\(artifact.rev)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 4)

            Text(artifact.updatedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)

            // Maintenance chip — show a dot if maintained by a cron.
            if !artifact.maintainerRefs.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
                    .help(maintenanceTooltip)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.4))
    }

    private var maintenanceTooltip: String {
        let refs = artifact.maintainerRefs
        if refs.count == 1, case .cron(let id) = refs[0] {
            let job = cronVM.jobs.first { $0.id == id }
            return "Maintained by \(job?.name ?? id)"
        }
        return "Maintained by \(refs.count) cron job\(refs.count == 1 ? "" : "s")"
    }

    private func refreshCrons() async {
        cronVM.setGatewayClient(gatewayClientWrapper.client)
        await cronVM.refreshJobs()
        if capabilitiesStore.capabilities.supportsActionLog {
            store.rehydrateBadges(for: artifact.id)
        }
    }
}
#endif
