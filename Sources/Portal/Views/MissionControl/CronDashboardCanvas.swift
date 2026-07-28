#if os(macOS)
import SwiftUI

/// Cron Activity canvas — the free-form panel counterpart to `CronDashboardView`.
/// Mirrors `SessionsDashboardCanvas`: a permanent two-row header (canvas
/// controls + the global time-horizon bar) over a `DashboardCanvasView` whose
/// panels are the cron sections (summary, volume, jobs, timeline, breakdown).
///
/// The horizon and jobs view-model live here, so every panel reads one
/// time-filtered record set — flipping the horizon updates all panels at once,
/// exactly like the scrolling `CronDashboardView`.
@MainActor
internal struct CronDashboardCanvas: View {
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject private var store = CronRunHistoryStore.shared

    @State private var cronListVM = CronListViewModel()
    @State private var timeHorizon: CronTimeHorizon = .day

    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var canvasBounds: CGSize = .zero
    @State private var isEditing = false
    @State private var showsTitleBars = true
    @State private var showAddPalette = false
    @AppStorage("cronDashboardToolbarCollapsed") private var toolbarCollapsed = false

    private let registry = CronDashboardCanvas.makeRegistry()

    private var filteredRecords: [CronRunRecord] {
        CronRunMetrics.filter(store.allRecordsSorted(), horizon: timeHorizon)
    }

    internal var body: some View {
        VStack(spacing: 0) {
            if toolbarCollapsed {
                collapsedBar
            } else {
                canvasBar
                Divider().overlay(Theme.border.opacity(0.4))
                horizonBar
            }
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    isEditing: isEditing,
                    showsTitleBars: showsTitleBars,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store(key: DashboardLayout.cronDashboardKey) },
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
        .task { await refreshData() }
    }

    private func refreshData() async {
        cronListVM.setGatewayClient(gatewayClientWrapper.client)
        await cronListVM.refreshJobs()
        store.seedFromJobs(cronListVM.jobs)
        store.detectNewRuns(from: cronListVM.jobs)
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

            Button {
                Task { await refreshData() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Refresh cron activity")

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
                if isEditing { layout.store(key: DashboardLayout.cronDashboardKey); showAddPalette = false }
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

    // MARK: - Horizon bar (row 2) — the permanent global time window

    private var horizonBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Text("Cron Activity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)

            Spacer()

            Picker("", selection: $timeHorizon) {
                ForEach(CronTimeHorizon.allCases, id: \.self) { h in
                    Text(h.rawValue).tag(h)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
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
        let records = filteredRecords
        switch panel.kind {
        case .cronSummary:
            return AnyView(ScrollView { CronSummaryView(records: records) })
        case .cronVolume:
            return AnyView(CronVolumeView(records: records, horizon: timeHorizon))
        case .cronJobs:
            return AnyView(ScrollView { CronJobsView(vm: cronListVM) })
        case .cronTimeline:
            return AnyView(ScrollView { CronTimelineView(records: records, horizon: timeHorizon) })
        case .cronBreakdown:
            return AnyView(ScrollView { CronBreakdownView(records: records) })
        default:
            return AnyView(PanelEmptyState(
                icon: "questionmark.square.dashed",
                message: "Unknown panel: \(panel.kind.rawValue)"
            ))
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
        let loaded = DashboardLayout.loadStored(key: DashboardLayout.cronDashboardKey)
            ?? DashboardLayout.seededCronDashboard(for: bounds)
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
        layout.store(key: DashboardLayout.cronDashboardKey)
    }

    private func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.18)) {
            layout = DashboardLayout.seededCronDashboard(for: canvasBounds)
            isEditing = false
        }
        layout.store(key: DashboardLayout.cronDashboardKey)
    }

    // MARK: - Registry

    private static func makeRegistry() -> PanelRegistry {
        let registry = PanelRegistry()
        registry.register(PanelDescriptor(kind: .cronSummary,   title: "Summary",   icon: "square.grid.2x2",     singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .cronVolume,    title: "Volume",    icon: "chart.bar.xaxis",     singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .cronJobs,      title: "Jobs",      icon: "clock.arrow.circlepath", singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .cronTimeline,  title: "Timeline",  icon: "timeline.selection",  singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .cronBreakdown, title: "Per-Job",   icon: "chart.bar.doc.horizontal", singleton: true, build: nil))
        return registry
    }
}
#endif
