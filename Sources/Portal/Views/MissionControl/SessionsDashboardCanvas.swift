#if os(macOS)
import SwiftUI

/// The sessions dashboard expressed as a free-form canvas — the same
/// `DashboardCanvasView` driver used by the chat canvas.
///
/// Three built-in panels, all host-rendered singletons:
///   - **Search** — text field + status/source filter pills; drives the shared `SessionsFilterState`
///   - **Sessions List** — card browser, responds to `SessionsFilterState`
///   - **Timeline** — horizontal Gantt plot of session start→end spans
@MainActor
internal struct SessionsDashboardCanvas: View {
    @EnvironmentObject private var sessionList: SessionListViewModel
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper

    internal var onOpenSession: ((String) -> Void)?

    @StateObject private var filterState = SessionsFilterState()

    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var canvasBounds: CGSize = .zero
    @State private var isEditing = false
    @State private var showsTitleBars = true
    @State private var showAddPalette = false
    @AppStorage("sessionsDashboardToolbarCollapsed") private var toolbarCollapsed = false

    private let registry = SessionsDashboardCanvas.makeRegistry()

    internal var body: some View {
        VStack(spacing: 0) {
            if toolbarCollapsed {
                collapsedToolbar
            } else {
                toolbar
            }
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    isEditing: isEditing,
                    showsTitleBars: showsTitleBars,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store(key: DashboardLayout.sessionsDashboardKey) },
                    content: { panel in panelContent(panel) }
                )
                .onAppear {
                    canvasBounds = geo.size
                    loadLayoutIfNeeded(bounds: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in canvasBounds = newSize }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Panel content

    private func panelContent(_ panel: DashboardPanel) -> AnyView {
        switch panel.kind {
        case .sessionsSearch:
            return AnyView(
                SessionsSearchPanel()
                    .environmentObject(filterState)
                    .environmentObject(sessionList)
            )
        case .sessionsList:
            return AnyView(
                SessionsListPanel(onOpenSession: onOpenSession)
                    .environmentObject(filterState)
                    .environmentObject(sessionList)
            )
        case .sessionsTimeline:
            return AnyView(
                SessionsTimelinePlot(
                    sessions: sessionList.sessions.filter { !$0.isArchived },
                    titles: { sessionList.titleForSession($0) },
                    onSelect: onOpenSession
                )
            )
        default:
            return AnyView(PanelEmptyState(
                icon: "questionmark.square.dashed",
                message: "Unknown panel: \(panel.kind.rawValue)"
            ))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: resetToDefault) {
                Label("Reset layout", systemImage: "rectangle.arrowtriangle.2.inward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Reset to the default layout")

            Spacer()

            Button {
                Task { await sessionList.refreshSessions(refreshCron: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Refresh sessions")

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
                if isEditing {
                    layout.store(key: DashboardLayout.sessionsDashboardKey)
                    showAddPalette = false
                }
                withAnimation(.easeInOut(duration: 0.15)) { isEditing.toggle() }
            } label: {
                Label(isEditing ? "Done" : "Edit",
                      systemImage: isEditing ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditing ? Theme.accent : Theme.secondary)
            .help(isEditing ? "Save arrangement and lock the canvas" : "Rearrange panels")

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
            .help("Collapse the toolbar")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface.opacity(0.5))
    }

    private var collapsedToolbar: some View {
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
            .help("Show the toolbar")
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Theme.surface.opacity(0.5))
    }

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
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
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
        guard !didLoadLayout else { return }
        didLoadLayout = true
        let loaded = DashboardLayout.loadStored(key: DashboardLayout.sessionsDashboardKey)
            ?? DashboardLayout.seededSessionsDashboard(for: bounds)
        layout = loaded.clamped(to: bounds)
    }

    private func addPanel(kind: PanelKind) {
        let size = CGSize(
            width: min(360, max(DashboardPanel.minSize.width, canvasBounds.width * 0.3)),
            height: min(400, max(DashboardPanel.minSize.height, canvasBounds.height * 0.5))
        )
        let frame = PanelResizeMath.vacantSlot(
            size: size, others: layout.panels.map(\.frame), bounds: canvasBounds
        )
        let panel = DashboardPanel(kind: kind, frame: frame).clamped(to: canvasBounds)
        layout.panels.append(panel)
        layout.bringToFront(panel.id)
        layout.store(key: DashboardLayout.sessionsDashboardKey)
    }

    private func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.18)) {
            layout = DashboardLayout.seededSessionsDashboard(for: canvasBounds)
            isEditing = false
        }
        layout.store(key: DashboardLayout.sessionsDashboardKey)
    }

    // MARK: - Registry

    private static func makeRegistry() -> PanelRegistry {
        let registry = PanelRegistry()
        registry.register(PanelDescriptor(
            kind: .sessionsSearch,
            title: "Search",
            icon: "magnifyingglass",
            singleton: true,
            build: nil  // host-rendered
        ))
        registry.register(PanelDescriptor(
            kind: .sessionsList,
            title: "Sessions",
            icon: "list.bullet.rectangle",
            singleton: true,
            build: nil  // host-rendered
        ))
        registry.register(PanelDescriptor(
            kind: .sessionsTimeline,
            title: "Timeline",
            icon: "timeline.selection",
            singleton: true,
            build: nil  // host-rendered
        ))
        return registry
    }
}
#endif
