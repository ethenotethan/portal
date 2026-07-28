#if os(macOS)
import SwiftUI

/// Sessions canvas — free-form panel surface with a permanent two-row header.
///
/// Row 1: canvas controls (Reset, Refresh, Add panel, headers toggle, Edit/Done, collapse).
/// Row 2: global filter bar — always visible, controls every panel simultaneously.
///   search · [All|Live|Ended] · Source ▾ · Time ▾ (with inline date picker) · Sort ▾ · × clear
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
    @State private var showDatePicker = false
    @State private var customDate = Date()
    @FocusState private var searchFocused: Bool
    @AppStorage("sessionsDashboardToolbarCollapsed") private var toolbarCollapsed = false

    private let registry = SessionsDashboardCanvas.makeRegistry()

    internal var body: some View {
        VStack(spacing: 0) {
            if toolbarCollapsed {
                collapsedBar
            } else {
                canvasBar
                Divider().overlay(Theme.border.opacity(0.4))
                filterBar
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
                Task { await sessionList.refreshSessions(refreshCron: false) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
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
                if isEditing { layout.store(key: DashboardLayout.sessionsDashboardKey); showAddPalette = false }
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

    // MARK: - Filter bar (row 2) — the permanent global controls

    private var filterBar: some View {
        HStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                TextField("Search…", text: $filterState.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .frame(width: 140)
                    .onKeyPress(.escape) {
                        filterState.searchText = ""
                        searchFocused = false
                        return .handled
                    }
                if !filterState.searchText.isEmpty {
                    Button { filterState.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 12)

            dividerSep

            // Status chips
            HStack(spacing: 4) {
                ForEach(SessionsFilterState.FilterStatus.allCases, id: \.self) { s in
                    statusChip(s)
                }
            }

            dividerSep

            // Source menu
            sourceMenu

            dividerSep

            // Time window menu + date picker
            timeMenu

            // Clear all — only when something is active
            if isFiltered {
                dividerSep
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        filterState.searchText = ""
                        filterState.filterStatus = .all
                        filterState.filterSource = nil
                        filterState.timeWindow = .all
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        Text("Clear").font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.red.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            // Sort
            sortMenu

            // Active-filter count badge
            if activeFilterCount > 0 {
                Text("\(activeFilterCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Theme.accent, in: Circle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: 36)
        .background(Theme.surface.opacity(0.3))
    }

    private var dividerSep: some View {
        Divider().frame(height: 14).padding(.horizontal, 6).opacity(0.5)
    }

    private func statusChip(_ status: SessionsFilterState.FilterStatus) -> some View {
        let active = filterState.filterStatus == status
        let color: Color = status == .live ? Theme.success : Theme.accent
        let count = countForStatus(status)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                filterState.filterStatus = active ? .all : status
            }
        } label: {
            HStack(spacing: 3) {
                Text(status.rawValue).font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(active ? color : Theme.tertiary)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(active ? color.opacity(0.15) : Color.clear)
            .foregroundStyle(active ? color : Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var sourceMenu: some View {
        let allSources = Set(
            sessionList.sessions
                .filter { !$0.isArchived && !$0.isCron }
                .map { $0.displaySource }
        ).sorted()

        return Menu {
            Button("All Sources") {
                withAnimation(.easeInOut(duration: 0.12)) { filterState.filterSource = nil }
            }
            if !allSources.isEmpty { Divider() }
            ForEach(allSources, id: \.self) { src in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        filterState.filterSource = filterState.filterSource == src ? nil : src
                    }
                } label: {
                    HStack {
                        Text(src)
                        if filterState.filterSource == src { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10))
                Text(filterState.filterSource ?? "Source").font(.caption.weight(.medium))
                if filterState.filterSource != nil {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filterState.filterSource != nil ? Theme.accent.opacity(0.15) : Color.clear)
            .foregroundStyle(filterState.filterSource != nil ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var timeMenu: some View {
        Menu {
            ForEach(SessionsFilterState.TimeWindow.presets, id: \.label) { w in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.timeWindow = w }
                } label: {
                    HStack {
                        Text(w.label)
                        if filterState.timeWindow == w { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button("Pick a date…") { showDatePicker = true }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 10))
                Text(filterState.timeWindow == .all ? "Time" : filterState.timeWindow.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filterState.timeWindow != .all ? Theme.accent.opacity(0.15) : Color.clear)
            .foregroundStyle(filterState.timeWindow != .all ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Show sessions since…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                DatePicker("", selection: $customDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 280)
                HStack {
                    Button("Cancel") { showDatePicker = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Apply") {
                        filterState.timeWindow = .since(customDate)
                        showDatePicker = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(14)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SessionsFilterState.SortOrder.allCases, id: \.self) { order in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.sortOrder = order }
                } label: {
                    HStack {
                        Text(order.rawValue)
                        if filterState.sortOrder == order { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                Text(filterState.sortOrder.rawValue).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filterState.sortOrder != .recent ? Theme.accent.opacity(0.15) : Color.clear)
            .foregroundStyle(filterState.sortOrder != .recent ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.trailing, 8)
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
                SessionsTimelinePlot(onSelect: { id in
                    filterState.selectedSessionID = id
                    onOpenSession?(id)
                })
                .environmentObject(filterState)
                .environmentObject(sessionList)
            )
        case .sessionsStats:
            return AnyView(
                SessionsStatsPanel()
                    .environmentObject(filterState)
                    .environmentObject(sessionList)
            )
        case .sessionsDetail:
            return AnyView(
                SessionsDetailPanel(onOpenSession: onOpenSession)
                    .environmentObject(filterState)
                    .environmentObject(sessionList)
            )
        case .sessionsSourceBreakdown:
            return AnyView(
                SessionsSourceBreakdown()
                    .environmentObject(filterState)
                    .environmentObject(sessionList)
            )
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

    // MARK: - Helpers

    private var isFiltered: Bool {
        !filterState.searchText.isEmpty
        || filterState.filterStatus != .all
        || filterState.filterSource != nil
        || filterState.timeWindow != .all
    }

    private var activeFilterCount: Int {
        [
            !filterState.searchText.isEmpty,
            filterState.filterStatus != .all,
            filterState.filterSource != nil,
            filterState.timeWindow != .all,
        ].filter { $0 }.count
    }

    private func countForStatus(_ status: SessionsFilterState.FilterStatus) -> Int {
        let base = sessionList.sessions.filter { !$0.isArchived && !$0.isCron }
        switch status {
        case .all:   return base.count
        case .live:  return base.filter { $0.isLive }.count
        case .ended: return base.filter { !$0.isLive }.count
        }
    }

    // MARK: - Layout helpers

    private func loadLayoutIfNeeded(bounds: CGSize) {
        guard !didLoadLayout, bounds.width > 0, bounds.height > 0 else { return }
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
        registry.register(PanelDescriptor(kind: .sessionsSearch,         title: "Search",    icon: "magnifyingglass",               singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .sessionsList,           title: "Sessions",  icon: "list.bullet.rectangle",         singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .sessionsTimeline,       title: "Timeline",  icon: "timeline.selection",            singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .sessionsStats,          title: "Stats",     icon: "chart.bar.xaxis",               singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .sessionsDetail,         title: "Inspector", icon: "sidebar.right",                 singleton: true, build: nil))
        registry.register(PanelDescriptor(kind: .sessionsSourceBreakdown,title: "By Source", icon: "chart.pie",                     singleton: true, build: nil))
        return registry
    }
}
#endif
