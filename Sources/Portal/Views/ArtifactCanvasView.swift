#if os(macOS)
import SwiftUI

/// Artifacts surface — switchable between a free-form canvas (one panel per
/// artifact) and a classic list+detail split. The canvas opens in VIEW mode:
/// each panel is a lightweight preview you click to expand full-screen. Edit
/// mode is opt-in (the Edit button) and makes panels draggable/resizable.
@MainActor
internal struct ArtifactCanvasView: View {
    @ObservedObject private var store = ArtifactStore.shared

    // Canvas state
    @State private var layout = DashboardLayout()
    @State private var didSeedLayout = false
    @State private var canvasBounds: CGSize = .zero
    // View mode by default — panels are previews you click to expand, not a
    // drag surface. Edit is opt-in via the toolbar Edit button.
    @State private var isEditing = false
    @State private var showsTitleBars = false

    // List state
    @State private var selectedID: String?
    @State private var expandedArtifact: LivingArtifact?

    // Shared
    @AppStorage("artifactViewMode") private var viewMode: ViewMode = .list
    // How each canvas cell renders: a simple, scannable preview card (default)
    // or the full live render (interactive charts / web views) tiled in place.
    // Either way a cell click expands the artifact full-screen.
    @AppStorage("artifactCellMode") private var cellMode: CellMode = .preview

    private enum ViewMode: String { case canvas, list }
    private enum CellMode: String { case preview, full }
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
        // Expand fills THIS surface edge-to-edge — an in-place takeover, not
        // a floating sheet, so "expand" actually reads as full screen.
        .overlay {
            if let artifact = expandedArtifact {
                ArtifactExpandedOverlay(artifact: artifact) {
                    expandedArtifact = nil
                }
                .environmentObject(gatewayClientWrapper)
                .environmentObject(capabilitiesStore)
                .transition(.opacity)
            }
        }
    }

    // environment objects needed for the expanded overlay
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
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
            .buttonStyle(.borderless)
            .help("Resync from harness")

            // View mode toggle
            HStack(spacing: 2) {
                ForEach([ViewMode.list, .canvas], id: \.rawValue) { mode in
                    Button {
                        if mode != viewMode {
                            isEditing = false
                            viewMode = mode
                        }
                    } label: {
                        Image(systemName: mode == .list ? "list.bullet" : "rectangle.3.group")
                            .font(.system(size: 11))
                            .foregroundStyle(viewMode == mode ? Theme.accent : Theme.tertiary)
                            .padding(6)
                            .background(
                                viewMode == mode ? Theme.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.borderless)
                    .help(mode == .list ? "List view" : "Canvas view")
                }
            }

            Divider().frame(height: 16).opacity(0.4)

            if viewMode == .canvas {
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

                // Cell render mode — simple preview cards (scannable) vs. the
                // full live render tiled in place. Click a cell to expand either
                // way.
                Button {
                    cellMode = cellMode == .preview ? .full : .preview
                } label: {
                    Image(systemName: cellMode == .preview ? "rectangle.grid.1x2" : "square.on.square")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
                .help(cellMode == .preview ? "Previews — click to expand. Switch to full render." : "Full render — switch to simple previews.")

                Toggle(isOn: $showsTitleBars) {
                    Image(systemName: showsTitleBars ? "rectangle.topthird.inset.filled" : "rectangle")
                        .font(.system(size: 11))
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
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

            // The overlay's Back button (ContentView) is the one way out of
            // this surface — no duplicate xmark here.
            if viewMode == .list, let artifact = selectedArtifact {
                Button {
                    expandedArtifact = artifact
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
                .help("Expand to full screen")
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
            // Same Rendered/History detail surface the iOS pane uses, so
            // revision attribution (who's revising: a cron, an agent session,
            // or you) is inspectable on macOS too.
            if let artifact = selectedArtifact {
                ArtifactDetailView(artifact: artifact)
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
                if let writer = WriterRef.parse(artifact.updatedBy) {
                    Text("· \(writer.label(cronName: { _ in nil }))")
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
            // In edit mode the move layer sits above the content and swallows
            // taps, so expand is disabled while rearranging (by design). In view
            // mode a click expands the artifact full-screen.
            ArtifactPanelContent(
                artifact: artifact,
                mode: cellMode == .preview ? .preview : .full,
                onExpand: isEditing ? nil : { expandedArtifact = artifact }
            )
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
        ArtifactKindGlyph.icon(for: artifactKind)
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
        // If the canvas seeded before store.pull() returned (empty store), and
        // artifacts have now arrived, re-seed with the full tiling algorithm.
        if layout.isEmpty, !artifactIDs.isEmpty {
            layout = Self.seededDefault(for: bounds, artifacts: store.sortedArtifacts)
            layout.store(key: Self.layoutKey)
            return
        }
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

// MARK: - Expanded full-screen overlay

/// Full-screen takeover showing a single artifact, layered over the artifacts
/// surface (not a floating sheet — expand means the artifact fills the
/// window). Collapse via the header button or Escape.
private struct ArtifactExpandedOverlay: View {
    let artifact: LivingArtifact
    let onDismiss: () -> Void

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @ObservedObject private var store = ArtifactStore.shared
    @State private var cronVM = CronListViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: kindIcon(for: artifact.kind))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(artifact.displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if artifact.rev > 0 {
                    Text("r\(artifact.rev)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 28, height: 28)
                        .background(Theme.surfaceHover, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Collapse")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.surface)

            Divider().overlay(Theme.border)

            // Content
            if artifact.kind == "html" {
                VStack(alignment: .leading, spacing: 0) {
                    ArtifactMaintenanceSection(artifact: artifact, jobs: cronVM.jobs)
                        .padding(20)
                    ArtifactKindRenderer(
                        kind: artifact.kind,
                        content: store.artifacts[artifact.id]?.content ?? artifact.content,
                        actionableArtifactID: artifact.id,
                        topLevelActions: artifact.topLevelActions
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ArtifactMaintenanceSection(artifact: artifact, jobs: cronVM.jobs)
                        ArtifactKindRenderer(
                            kind: artifact.kind,
                            content: store.artifacts[artifact.id]?.content ?? artifact.content,
                            actionableArtifactID: artifact.id,
                            topLevelActions: artifact.topLevelActions
                        )
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refreshCrons() }
    }

    private func refreshCrons() async {
        cronVM.setGatewayClient(gatewayClientWrapper.client)
        await cronVM.refreshJobs()
        if capabilitiesStore.capabilities.supportsActionLog {
            store.rehydrateBadges(for: artifact.id)
        }
    }

    private func kindIcon(for kind: String) -> String {
        switch kind {
        case "map": return "map"
        case "chart": return "chart.xyaxis.line"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "square.grid.2x2"
        case "dataset": return "tablecells"
        case "checklist": return "checklist"
        case "kanban": return "rectangle.split.3x1"
        case "calendar": return "calendar"
        case "timeline": return "calendar.day.timeline.left"
        case "sankey": return "arrow.triangle.branch"
        case "model": return "cube.transparent"
        case "model3d": return "cube.transparent.fill"
        case "html": return "globe"
        default: return "doc.text"
        }
    }
}

// MARK: - Per-artifact panel content

/// Renders a single artifact's cell inside a canvas panel. Two modes:
/// - `.preview` (default): a simple, scannable card — kind glyph, title, meta,
///   and a short content gist. Cheap (no live web views / interactive charts),
///   easy for a human to reason about. Click to expand full-screen.
/// - `.full`: the live `ArtifactKindRenderer` tiled in place, under a compact
///   mini-header. The old behavior, now opt-in.
/// Both are click-to-expand (via `onExpand`, nil while editing the layout).
private struct ArtifactPanelContent: View {
    let artifact: LivingArtifact
    var mode: Mode = .preview
    /// Expand this artifact full-screen. Nil disables the tap (edit mode, where
    /// the move layer owns taps).
    var onExpand: (() -> Void)?

    internal enum Mode { case preview, full }

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @ObservedObject private var store = ArtifactStore.shared
    @State private var cronVM = CronListViewModel()
    @State private var isHovering = false

    var body: some View {
        Group {
            switch mode {
            case .preview: previewCard
            case .full:    fullRender
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await refreshCrons() }
    }

    // MARK: - Preview card (simple, scannable)

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: ArtifactKindGlyph.icon(for: artifact.kind))
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    metaLine
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 8)

            Divider().overlay(Theme.border.opacity(0.35))

            Text(previewGist)
                .font(.system(size: 11, design: gistIsMonospaced ? .monospaced : .default))
                .foregroundStyle(Theme.secondary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) { expandAffordance }
        .contentShape(Rectangle())
        .onTapGesture { onExpand?() }
        .onHover { isHovering = $0 }
        .help(onExpand == nil ? "" : "Click to expand \(artifact.displayName)")
    }

    /// A small "expand" chip that surfaces on hover so the click target reads as
    /// "open this", not just a static tile. Hidden while editing (no onExpand).
    @ViewBuilder
    private var expandAffordance: some View {
        if onExpand != nil, isHovering {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Expand")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceHover, in: Capsule())
            .padding(8)
            .transition(.opacity)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(artifact.kind)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.accent)
            if artifact.rev > 0 {
                Text("r\(artifact.rev)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(artifact.updatedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            if !artifact.maintainerRefs.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
                    .help(maintenanceTooltip)
            }
        }
    }

    /// A short, human-scannable gist of the artifact without a live render:
    /// a one-line structural summary for JSON kinds (e.g. "12 markers"), the
    /// leading prose for docs, or a code/markup snippet otherwise.
    private var previewGist: String {
        let content = store.artifacts[artifact.id]?.content ?? artifact.content
        return ArtifactPreviewGist.make(kind: artifact.kind, content: content)
    }

    private var gistIsMonospaced: Bool {
        artifact.kind == "html" || artifact.kind == "model"
    }

    // MARK: - Full render (opt-in, live)

    private var fullRender: some View {
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

            // Explicit expand — the full render's live content owns taps, so a
            // cell tap can't reliably reach an expand handler; this button is
            // the way out to full screen. Hidden while editing (onExpand nil).
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
                .help("Expand to full screen")
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

// MARK: - Kind glyph

/// SF Symbol per artifact kind — shared by the preview card, the mini-header,
/// and the panel-icon lookup so one map governs all of them.
internal enum ArtifactKindGlyph {
    internal static func icon(for kind: String) -> String {
        switch kind {
        case "map": return "map"
        case "chart": return "chart.xyaxis.line"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "square.grid.2x2"
        case "dataset": return "tablecells"
        case "checklist": return "checklist"
        case "kanban": return "rectangle.split.3x1"
        case "calendar": return "calendar"
        case "timeline": return "calendar.day.timeline.left"
        case "sankey": return "arrow.triangle.branch"
        case "model": return "cube.transparent"
        case "model3d": return "cube.transparent.fill"
        case "html": return "globe"
        default: return "doc.text"
        }
    }
}

// MARK: - Preview gist

/// A cheap, human-scannable one-glance summary of an artifact WITHOUT a live
/// render — the text a preview card shows. For structured (JSON) kinds it's a
/// count-based structural line ("12 markers · Bangkok"); for docs it's the
/// leading prose; for html/model it's a trimmed code snippet. Never parses
/// more than it needs and never renders a web view / chart.
internal enum ArtifactPreviewGist {
    internal static func make(kind: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty artifact" }

        switch kind {
        case "map":       return structural(trimmed, list: "markers", noun: "marker", titleKey: "title")
        case "dataset":   return structural(trimmed, list: "rows", noun: "row", titleKey: "title")
        case "checklist": return structural(trimmed, list: "items", noun: "item", titleKey: "title")
        case "kanban":    return structural(trimmed, list: "cards", noun: "card", titleKey: "title")
        case "calendar":  return structural(trimmed, list: "events", noun: "event", titleKey: "title")
        case "graph":     return structural(trimmed, list: "nodes", noun: "node", titleKey: "title")
        case "stats":     return structural(trimmed, list: "tiles", noun: "stat", titleKey: "title")
        case "chart", "sankey", "timeline", "model", "html":
            // Structured/markup kinds with no simple count worth surfacing:
            // show a trimmed snippet of the source so the card isn't empty.
            return snippet(trimmed)
        default:
            // Markdown/doc — the leading prose reads as its own summary.
            return snippet(trimmed)
        }
    }

    /// "<n> <noun>s · <title>" for a JSON object with a top-level array.
    /// Falls back to a snippet when the content isn't the expected shape.
    private static func structural(_ content: String, list: String, noun: String, titleKey: String) -> String {
        guard let data = content.data(using: .utf8) else { return snippet(content) }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return snippet(content)   // not JSON (or malformed) — fall back to a text snippet
        }
        guard let obj = parsed as? [String: Any] else { return snippet(content) }
        var parts: [String] = []
        if let items = obj[list] as? [Any] {
            let live = items.filter { ($0 as? [String: Any])?["_deleted"] as? Bool != true }.count
            parts.append("\(live) \(noun)\(live == 1 ? "" : "s")")
        }
        if let title = obj[titleKey] as? String, !title.isEmpty {
            parts.append(title)
        }
        return parts.isEmpty ? snippet(content) : parts.joined(separator: " · ")
    }

    /// First few non-empty lines, capped, for a text/markup gist.
    private static func snippet(_ content: String) -> String {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(6)
        let joined = lines.joined(separator: "\n")
        return joined.count > 400 ? String(joined.prefix(400)) + "…" : joined
    }
}

#endif
