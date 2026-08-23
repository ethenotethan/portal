import SwiftUI

// MARK: - WikiGraphView

/// The wiki's ONE adaptive surface. The graph IS the wiki home:
/// - No page selected → full-bleed force-directed graph (2D canvas by
///   default; 3D SceneKit is a rendering toggle in the controls bar).
/// - Selecting a page (graph node, file-tree sidebar, or search) opens the
///   reader over the always-alive graph: on macOS a right-docked panel with a
///   draggable divider and a fullscreen toggle (pin pages to compare them
///   side-by-side); on iOS a sheet. Deselect/close → back to the full graph.
/// - The folder tree is a toggleable left sidebar (macOS) / sheet (iOS).
/// - The changeset timeline is a bottom drawer (macOS) / sheet (iOS) with
///   git-style inline diffs; shown only for sources with edit history
///   (WikiChangesetSource conformance).
/// - The events page (sources with an ingestion log, by WikiEventLogSource
///   conformance — both backends) is a full-surface page WITHIN the wiki:
///   `showEventsPage` swaps the whole surface graph ↔ events, with "← Wiki"
///   navigating back — never a sheet/overlay.
/// Selection stays synced across every surface via the view model's shared
/// selection plane.
struct WikiGraphView: View {
    /// Knowledge-base source override. nil = the Hermes home gateway
    /// (existing behavior); a Centaur session passes its wiki-api client so
    /// the same graph/reader/sidebar UI renders the Darkbloom KB.
    var overrideSource: (any WikiSource)?

    @ObservedObject internal var viewModel: WikiGraphViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    @MainActor
    internal init(viewModel: WikiGraphViewModel? = nil, overrideSource: (any WikiSource)? = nil) {
        self.viewModel = viewModel ?? WikiGraphViewModel()
        self.overrideSource = overrideSource
    }

    /// Hermes-only chrome (wiki picker, taxonomy from wiki.list) hides when
    /// browsing an override source — those RPCs don't exist there.
    private var isOverride: Bool { overrideSource != nil }

    /// Changeset timeline is a source capability, not a backend-kind check:
    /// the drawer affordance exists iff the active source records history.
    private var supportsTimeline: Bool {
        if let overrideSource { return overrideSource is WikiChangesetSource }
        return true // home gateway conforms
    }

    /// Events-page capability. Both backends have an ingestion log — Hermes via
    /// `wiki.events`, Centaur via `/wiki/timeline` — so this resolves to the
    /// home gateway when there's no override. nil hides the affordance and
    /// keeps `showEventsPage` inert.
    private var eventLogSource: (any WikiEventLogSource)? {
        if let overrideSource { return overrideSource as? (any WikiEventLogSource) }
        return gatewayClientWrapper.client
    }

    /// Whether the Events door belongs in the toolbar. Distinct from
    /// `showsEventsPage`, which also requires the page to be *open* — and the
    /// toolbar only renders while it's closed, so gating the door on that would
    /// hide it exactly when it's needed.
    private var hasEventsSurface: Bool { eventLogSource != nil }

    @State private var showWikiPicker = false
    @State private var lastPinchScale: CGFloat = 1.0

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    #if os(macOS)
    private let sidebarWidth: CGFloat = 240
    private let timelineHeight: CGFloat = 300
    #endif

    /// Load through the override source when present, else the home gateway.
    /// `wiki` (multi-wiki selection) is Hermes-only and ignored on overrides.
    private func loadGraph(wiki: String?, generation: Int? = nil) async {
        if let overrideSource {
            await viewModel.load(source: overrideSource, generation: generation)
        } else {
            await viewModel.load(
                client: gatewayClientWrapper.client,
                wiki: wiki,
                generation: generation
            )
        }
    }

    /// Commit selection state before starting the asynchronous scan. The
    /// custom-path sheet previously loaded a wiki without updating the picker,
    /// leaving subsequent named-menu switches anchored to stale state.
    private func selectAndLoadWiki(_ wiki: String?) {
        let generation = viewModel.selectWiki(wiki)
        Task { await loadGraph(wiki: wiki, generation: generation) }
    }

    // MARK: - Body

    var body: some View {
        adaptiveLayout
            .background(Theme.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(timer) { _ in
                guard !viewModel.isSettling else { return }
                guard viewModel.simAlpha > 0.003 || viewModel.simNodes.contains(where: { $0.isDragging }) else { return }
                viewModel.tick()
            }
            .onChange(of: viewModel.zoom) { _, _ in
                lastPinchScale = viewModel.zoom
            }
            .sheet(isPresented: $showWikiPicker) {
                WikiPathPickerSheet(
                    selectedPath: $viewModel.selectedWikiPath,
                    onSelect: { path in
                        selectAndLoadWiki(path)
                    }
                )
            }
            .onAppear {
                // For override sources (Centaur), always load — the source
                // changes per session and the VM is shared from ContentView.
                // For the home gateway, skip if the graph is already populated:
                // ContentView warms it at connect (see the isConnected handler),
                // so opening the panel usually finds it loaded and paints
                // instantly instead of re-fetching. Only cold cases (prefetch
                // still in flight, or it failed) fall through to load here.
                guard isOverride || viewModel.graph.pages.isEmpty else { return }
                Task { await attemptInitialLoad() }
            }
            .onChange(of: gatewayClientWrapper.isConnected) { _, connected in
                // The home-gateway graph loads over the WebSocket. If the view
                // appeared before the socket finished connecting, the first
                // wiki.scan threw .notConnected and left the surface blank with
                // no recovery — the "sometimes it doesn't load" bug. Retry once
                // the connection comes up, but only while we still have no data
                // (don't disrupt a loaded graph on a mid-session reconnect) and
                // only for the home gateway (override sources use REST, not the
                // WS, so isConnected is irrelevant to them).
                guard connected, !isOverride, viewModel.graph.pages.isEmpty else { return }
                Task { await attemptInitialLoad() }
            }
    }

    /// Discover wikis, then load the selected graph. Safe to call more than
    /// once: the view model drops stale responses by generation, and the
    /// retry-on-connect path guards on an empty graph so this never stacks
    /// redundant loads over live data.
    private func attemptInitialLoad() async {
        // wiki.list (the picker/taxonomy chrome) and wiki.scan (the graph) are
        // independent RPCs. Running them concurrently instead of serially means
        // the graph no longer waits on the list — it paints as soon as the scan
        // returns (or instantly from cache). Override sources ignore the list.
        let client = gatewayClientWrapper.client
        async let wikis: Void = isOverride ? () : viewModel.discoverWikis(client: client)
        async let graph: Void = loadGraph(wiki: viewModel.selectedWikiPath)
        _ = await (wikis, graph)
    }

    // MARK: - Adaptive layout

    /// True while the events page owns the wiki surface. Gated on the
    /// capability so a stale flag can never blank a wiki whose source has no
    /// event log.
    private var showsEventsPage: Bool {
        viewModel.showEventsPage && hasEventsSurface
    }

    #if os(macOS)
    /// macOS: sidebar | (graph / timeline drawer) | reader panel — or the
    /// full-surface events page when navigated there.
    @ViewBuilder
    private var adaptiveLayout: some View {
        if let eventLogSource, showsEventsPage {
            WikiEventsPageView(source: eventLogSource, viewModel: viewModel)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            graphLayout
        }
    }

    private var graphLayout: some View {
        HStack(spacing: 0) {
            if viewModel.showFileTree {
                WikiFileTreeSidebar(viewModel: viewModel) { page in
                    viewModel.navigate(to: page.path)
                    viewModel.openReaderForSelection()
                }
                .frame(width: sidebarWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            VStack(spacing: 0) {
                // The graph and the right-docked reader sit side-by-side (Peek):
                // clicking a node opens the reader beside the always-alive graph,
                // a draggable divider resizes it, and a toggle fills it over the
                // whole surface (fullscreen). A page is open iff showPageDetail.
                readerSurface

                if viewModel.showTimeline && supportsTimeline {
                    Divider()
                    WikiTimelineView(
                        wiki: viewModel.selectedWikiPath,
                        selectedPagePath: viewModel.selectedPath,
                        eventTypes: viewModel.eventTypes,
                        onOpenPage: { path in openPageFromTimeline(path) },
                        onOpenEvent: onOpenEvent,
                        onClose: { viewModel.showTimeline = false }
                    )
                    .frame(height: timelineHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showFileTree)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showTimeline)
    }

    /// Graph beside the right-docked reader (Peek), or the reader filling the
    /// whole surface (fullscreen). Reads its own width so the divider drag can
    /// clamp the panel against the live surface size.
    private var readerSurface: some View {
        GeometryReader { geo in
            let showReader = viewModel.showPageDetail && viewModel.selectedPath != nil
            HStack(spacing: 0) {
                if !(showReader && viewModel.readerFullscreen) {
                    graphSurface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showReader {
                    WikiDockedReader(viewModel: viewModel, surfaceWidth: geo.size.width)
                        .frame(width: readerPanelWidth(surface: geo.size.width))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.18), value: viewModel.showPageDetail)
            .animation(.easeInOut(duration: 0.18), value: viewModel.readerFullscreen)
        }
    }

    /// Peek: the user-set panel width, clamped to the live surface. Fullscreen:
    /// the whole surface (the graph is dropped from the HStack above).
    private func readerPanelWidth(surface: CGFloat) -> CGFloat {
        if viewModel.readerFullscreen { return surface }
        let maxWidth = max(WikiGraphViewModel.minReaderWidth, surface * 0.7)
        return min(max(WikiGraphViewModel.minReaderWidth, viewModel.readerWidth), maxWidth)
    }
    #else
    /// iOS: full-bleed graph; sidebar, reader, and timeline present as
    /// sheets — or the full-surface events page when navigated
    /// there. Page chips on the events page navigate back to the graph
    /// surface first (openPageLeavingEvents), so the reader sheet always
    /// presents from the graph branch.
    @ViewBuilder
    private var adaptiveLayout: some View {
        if let eventLogSource, showsEventsPage {
            WikiEventsPageView(source: eventLogSource, viewModel: viewModel)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            graphLayout
        }
    }

    private var graphLayout: some View {
        graphSurface
            .sheet(isPresented: readerSheetBinding) {
                WikiReaderPane(
                    viewModel: viewModel,
                    onClose: { viewModel.showPageDetail = false }
                )
            }
            .sheet(isPresented: $viewModel.showFileTree) {
                WikiFileTreeSidebar(viewModel: viewModel) { page in
                    viewModel.showFileTree = false
                    viewModel.navigate(to: page.path)
                    viewModel.openReaderForSelection()
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $viewModel.showTimeline) {
                WikiTimelineView(
                    wiki: viewModel.selectedWikiPath,
                    selectedPagePath: viewModel.selectedPath,
                    eventTypes: viewModel.eventTypes,
                    onOpenPage: { path in
                        viewModel.showTimeline = false
                        openPageFromTimeline(path)
                    },
                    onOpenEvent: onOpenEvent,
                    onClose: { viewModel.showTimeline = false }
                )
                .environmentObject(gatewayClientWrapper)
                .presentationDetents([.medium, .large])
            }
    }

    /// Reader presents whenever a page is open — the graph never leaves.
    private var readerSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showPageDetail && viewModel.selectedPath != nil },
            set: { viewModel.showPageDetail = $0 }
        )
    }
    #endif

    // MARK: - Graph surface (always alive)

    private var graphSurface: some View {
        ZStack {
            if viewModel.is3D {
                WikiGraph3DView(viewModel: viewModel)
            } else {
                WikiGraph2DCanvas(viewModel: viewModel)
                    .gesture(pinchGesture)
                    // The layout relaxes off-screen, so the random seed frame
                    // never shows; reveal the framed graph with a quick fade
                    // instead of an on-screen explosion.
                    .opacity(viewModel.isSettling ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: viewModel.isSettling)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { graphStatusOverlay }
        .overlay(alignment: .topLeading) { infoOverlay }
        .overlay(alignment: .topTrailing) {
            WikiGraphControlsBar(
                viewModel: viewModel,
                supportsTimeline: supportsTimeline,
                hasEventsSurface: hasEventsSurface,
                onRefresh: { Task { await loadGraph(wiki: viewModel.selectedWikiPath) } }
            )
        }
    }

    /// Centered status shown only when the graph has no nodes to draw, so a
    /// cold-connect failure, an in-flight load, and a genuinely empty wiki are
    /// no longer indistinguishable blank canvases. Hidden the moment real
    /// nodes exist.
    @ViewBuilder
    private var graphStatusOverlay: some View {
        if !viewModel.graph.pages.isEmpty && viewModel.isSettling {
            // The graph is loaded but the 2D canvas hides itself (opacity 0)
            // while it relaxes the layout off-thread — see graphSurface's
            // `.opacity(isSettling ? 0 : 1)`. Without this the surface is a
            // blank rectangle for the settle window (hundreds of ms up to a
            // couple seconds on a large graph) on first open, since the
            // empty-graph branch below doesn't fire. Show a spinner so the
            // surface reads as "laying out", not broken.
            VStack(spacing: 10) {
                ProgressView()
                Text("Laying out…")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(24)
            .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
            .transition(.opacity)
        } else if viewModel.graph.pages.isEmpty {
            VStack(spacing: 10) {
                if viewModel.isLoading {
                    ProgressView()
                    Text("Loading…")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                } else if !isOverride && !gatewayClientWrapper.isConnected {
                    // No spinner once the transport has given up — a permanent
                    // spinner next to "Connecting…" was the whole complaint.
                    if gatewayClientWrapper.connectionErrorMessage == nil {
                        ProgressView()
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(Theme.warning)
                    }
                    Text(gatewayClientWrapper.isConnecting
                         ? gatewayClientWrapper.statusLabel
                         : (gatewayClientWrapper.connectionErrorMessage ?? "Waiting for harness…"))
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                } else if let error = viewModel.error {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(Theme.warning)
                    Text("Couldn't load the wiki")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.primary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 320)
                    Button("Try again") {
                        Task { await loadGraph(wiki: viewModel.selectedWikiPath) }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "square.dashed")
                        .font(.title2)
                        .foregroundStyle(Theme.tertiary)
                    Text("This wiki has no pages yet")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(24)
            .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
            .transition(.opacity)
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let targetZoom = lastPinchScale * value
                let clamped = max(0.3, min(5.0, targetZoom))
                let oldZoom = viewModel.zoom
                guard abs(clamped - oldZoom) > 0.001 else { return }
                let c = CGPoint(x: viewModel.canvasSize.width / 2,
                                y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: clamped / oldZoom, around: c)
            }
            .onEnded { _ in
                lastPinchScale = viewModel.zoom
            }
    }

    // MARK: - Info overlay (title, picker, counts, search)

    private var infoOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Wiki")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)

                if !isOverride { wikiPickerMenu }
            }
            Text("\(viewModel.graph.pages.count) pages · \(viewModel.graph.links.count) links")
                .font(.caption)
                .foregroundStyle(Theme.secondary)

            if viewModel.isFiltering {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    Text("\(viewModel.filteredNodeIndices.count) of \(viewModel.simNodes.count) nodes")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 4) {
                TextField("Search…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(minWidth: 80)
                    .onSubmit { /* just focus — filtering is live */ }
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(10)
        .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    // MARK: - Wiki picker

    @ViewBuilder
    private var wikiPickerMenu: some View {
        Menu {
            Button("Default wiki") {
                selectAndLoadWiki(nil)
            }
            Divider()
            ForEach(viewModel.availableWikis, id: \.self) { wiki in
                Button(wiki) {
                    selectAndLoadWiki(wiki)
                }
            }
            if viewModel.availableWikis.isEmpty {
                Text("No wikis discovered")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Divider()
            Button {
                showWikiPicker = true
            } label: {
                Label("Enter custom path…", systemImage: "pencil")
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedWikiPath ?? "default")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceHover, in: Capsule())
        }
        .buttonStyle(.borderless)
    }

    /// Open a wiki page from a timeline row through the shared selection
    /// plane: the page becomes the current page (history included) and the
    /// reader presents it. Pages not in the graph still load — the reader
    /// fetches by path.
    private func openPageFromTimeline(_ path: String) {
        viewModel.navigate(to: path)
        viewModel.openReaderForSelection()
    }

    /// Provenance chip → the event feed, but only where there IS one. Handing
    /// the timeline a nil closure when the source has no event log is what makes
    /// its chips render as plain labels instead of dead buttons.
    private var onOpenEvent: ((String) -> Void)? {
        guard hasEventsSurface else { return nil }
        return { key in
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.openEventFeed(eventKey: key)
            }
        }
    }
}
