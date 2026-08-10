#if os(macOS)
import SwiftUI

/// Skills canvas — the free-form panel counterpart to `SkillsView`.
///
/// Mirrors `CronDashboardCanvas` and `SessionsDashboardCanvas`: a two-row header
/// (canvas controls + the surface's own filter bar) over a `DashboardCanvasView`
/// whose panels are the skills lenses — folder tree, roll-down list, search,
/// stats, detail, editor, hub.
///
/// The view model and `SkillsFilterState` live here, so every panel reads one
/// filtered skill set: typing in the search panel narrows the list and the stats
/// at once, and scoping the folder tree scopes everything downstream. That shared
/// state is the whole reason the surface decomposes into panels rather than being
/// one scrolling column.
@MainActor
internal struct SkillsCanvasView: View {
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var settings: SettingsViewModel

    @State private var viewModel = SkillsViewModel()
    @StateObject private var filterState = SkillsFilterState()

    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var canvasBounds: CGSize = .zero
    @State private var isEditing = false
    @State private var showsTitleBars = true
    @State private var showAddPalette = false
    @AppStorage("skillsDashboardToolbarCollapsed") private var toolbarCollapsed = false

    private let registry = SkillsCanvasView.makeRegistry()

    internal var body: some View {
        VStack(spacing: 0) {
            if toolbarCollapsed {
                collapsedBar
            } else {
                canvasBar
                Divider().overlay(Theme.border.opacity(0.4))
                titleBar
            }
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    isEditing: isEditing,
                    showsTitleBars: showsTitleBars,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store(key: DashboardLayout.skillsDashboardKey) },
                    content: { panelContent($0) }
                )
                .onAppear {
                    canvasBounds = geo.size
                    loadLayoutIfNeeded(bounds: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in
                    canvasBounds = newSize
                    loadLayoutIfNeeded(bounds: newSize)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .environmentObject(filterState)
        .task(id: settings.focusedGateway?.id) { await connectAndLoad() }
    }

    // MARK: - Backend wiring

    /// Same dual-mode routing as `SkillsView`: a focused Standard backend is
    /// HTTP-only and goes through the dashboard API; everything else uses the
    /// WebSocket Gateway.
    private func connectAndLoad() async {
        if let standard = settings.focusedGateway, standard.kind == .hermesStandard,
           let client = Self.standardClient(for: standard) {
            viewModel.setStandardClient(client)
            await viewModel.refreshStandard()
        } else {
            viewModel.setGatewayClient(gatewayClientWrapper.client)
            // Warm the local summarization model (downloads on first use) so the
            // detail panel has a summary ready by the time a skill is selected.
            SkillSummaryService.shared.warmUp()
            if gatewayClientWrapper.isConnected {
                await viewModel.refreshIfNeeded()
            }
        }
    }

    /// Build an upstream Hermes dashboard client for a focused Standard gateway.
    private static func standardClient(for gateway: SavedGateway) -> HermesStandardClient? {
        // GatewayURL, not URL(string:) — a bare "host:8080" parses as a host-less
        // URL and yields no client at all.
        guard let baseURL = GatewayURL.httpOrigin(gateway.url) else { return nil }
        do {
            return try HermesStandardClient(baseURL: baseURL, sessionToken: gateway.apiKey)
        } catch {
            return nil
        }
    }

    private func refresh() async {
        if viewModel.isStandardMode {
            await viewModel.refreshStandard()
        } else {
            await viewModel.reload()
        }
    }

    // MARK: - Canvas bar (row 1)

    private var canvasBar: some View {
        HStack(spacing: 10) {
            Button(action: resetToDefault) {
                Label("Reset layout", systemImage: "rectangle.arrowtriangle.2.inward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Reset to the default layout")

            Spacer()

            if viewModel.isLoading {
                PortalProgressView().scaleEffect(0.5)
            }

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .disabled(viewModel.isLoading)
            .help("Reload skills from the harness")

            if isEditing {
                Button { showAddPalette.toggle() } label: {
                    Label("Add panel", systemImage: "plus.rectangle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .popover(isPresented: $showAddPalette, arrowEdge: .bottom) { addPalette }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsTitleBars.toggle() }
            } label: {
                Image(systemName: showsTitleBars ? "menubar.rectangle" : "rectangle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsTitleBars ? Theme.secondary : Theme.accent)
            .help(showsTitleBars ? "Hide panel headers" : "Show panel headers")

            Button {
                if isEditing { layout.store(key: DashboardLayout.skillsDashboardKey); showAddPalette = false }
                withAnimation(.easeInOut(duration: 0.15)) { isEditing.toggle() }
            } label: {
                Label(isEditing ? "Done" : "Edit",
                      systemImage: isEditing ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditing ? Theme.accent : Theme.secondary)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toolbarCollapsed = true }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: - Title bar (row 2)

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Text("Skills")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)

            if let error = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            } else if !viewModel.isStandardMode && !gatewayClientWrapper.isConnected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                Text("Harness disconnected")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer()

            if filterState.hasActiveFilters {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.clearFilters() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle").font(.system(size: 9))
                        Text("Clear filters").font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            Text("\(filterState.filtered(viewModel.skills).count) of \(viewModel.skills.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 36)
        .background(Theme.surface.opacity(0.3))
    }

    // MARK: - Collapsed bar

    private var collapsedBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toolbarCollapsed = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: - Panel content

    private func panelContent(_ panel: DashboardPanel) -> AnyView {
        switch panel.kind {
        case .skillsSearch:
            return AnyView(SkillsSearchPanel(skills: viewModel.skills))
        case .skillsList:
            return AnyView(SkillsListPanel(
                viewModel: viewModel,
                onViewMarkdown: { skill in openEditor(for: skill) }
            ))
        case .skillsFolders:
            return AnyView(SkillsFolderPanel(skills: viewModel.skills))
        case .skillsDetail:
            return AnyView(SkillsDetailPanel(viewModel: viewModel))
        case .skillsEditor:
            return AnyView(SkillsEditorPanel(viewModel: viewModel))
        case .skillsStats:
            return AnyView(SkillsStatsPanel(skills: viewModel.skills))
        case .skillsHub:
            return AnyView(SkillsHubPanel(viewModel: viewModel))
        default:
            return AnyView(PanelEmptyState(
                icon: "questionmark.square.dashed",
                message: "Unknown panel: \(panel.kind.rawValue)"
            ))
        }
    }

    /// "Edit Markdown" on a card opens the editor *panel* rather than a sheet —
    /// the point of the canvas is that a lens docks instead of covering. Adds the
    /// panel if the user hasn't placed one yet, otherwise raises the existing one.
    private func openEditor(for skill: SkillInfo) {
        filterState.selectedSkillName = skill.name
        if let existing = layout.panels.first(where: { $0.kind == .skillsEditor }) {
            withAnimation(.easeInOut(duration: 0.15)) { layout.bringToFront(existing.id) }
        } else {
            addPanel(kind: .skillsEditor)
        }
    }

    // MARK: - Add palette

    private var addPalette: some View {
        let present = layout.panels.map(\.kind)
        let options = registry.addableDescriptors(present: present)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Add panel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 4)
            if options.isEmpty {
                Text("Every panel is already visible.")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            } else {
                ForEach(options) { descriptor in
                    Button {
                        addPanel(kind: descriptor.kind)
                        showAddPalette = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: descriptor.icon).frame(width: 16).foregroundStyle(Theme.accent)
                            Text(descriptor.title).foregroundStyle(Theme.primary)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 200)
    }

    // MARK: - Layout helpers

    private func loadLayoutIfNeeded(bounds: CGSize) {
        guard !didLoadLayout, bounds.width > 0, bounds.height > 0 else { return }
        didLoadLayout = true
        let loaded = DashboardLayout.loadStored(key: DashboardLayout.skillsDashboardKey)
            ?? DashboardLayout.seededSkillsDashboard(for: bounds)
        layout = loaded.clamped(to: bounds)
    }

    private func addPanel(kind: PanelKind) {
        let size = CGSize(
            width: min(420, max(DashboardPanel.minSize.width, canvasBounds.width * 0.32)),
            height: min(460, max(DashboardPanel.minSize.height, canvasBounds.height * 0.55))
        )
        let frame = PanelResizeMath.vacantSlot(
            size: size, others: layout.panels.map(\.frame), bounds: canvasBounds
        )
        let panel = DashboardPanel(kind: kind, frame: frame).clamped(to: canvasBounds)
        layout.panels.append(panel)
        layout.bringToFront(panel.id)
        layout.store(key: DashboardLayout.skillsDashboardKey)
    }

    private func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.18)) {
            layout = DashboardLayout.seededSkillsDashboard(for: canvasBounds)
            isEditing = false
        }
        layout.store(key: DashboardLayout.skillsDashboardKey)
    }

    // MARK: - Registry

    private static func makeRegistry() -> PanelRegistry {
        let registry = PanelRegistry()
        registry.register(PanelDescriptor(kind: .skillsSearch,  title: "Search",  icon: "magnifyingglass",     singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .skillsFolders, title: "Folders", icon: "folder",              singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .skillsList,    title: "Skills",  icon: "list.bullet.indent",  singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .skillsStats,   title: "Stats",   icon: "square.grid.2x2",     singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .skillsDetail,  title: "Detail",  icon: "sidebar.right",       singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .skillsEditor,  title: "Editor",  icon: "doc.text",            singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .skillsHub,     title: "Hub",     icon: "square.and.arrow.down", singleton: true, build: nil))
        return registry
    }
}
#endif
