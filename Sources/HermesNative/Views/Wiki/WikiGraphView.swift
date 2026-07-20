import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Mouse Interceptor (NSView)

/// A transparent NSView that captures mouseDown / mouseDragged / mouseUp
/// and forwards them as callbacks.  This bypasses the broken SwiftUI
/// DragGesture-on-Canvas path on macOS.
final class GraphMouseView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onScrollWheel: ((CGSize) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseDown?(pt)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseDragged?(pt)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseUp?(pt)
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseMoved?(pt)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        onScrollWheel?(delta)
    }
}

/// SwiftUI wrapper for GraphMouseView.
struct GraphMouseInterceptor: NSViewRepresentable {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onScrollWheel: ((CGSize) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    func makeNSView(context: Context) -> GraphMouseView {
        let v = GraphMouseView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onScrollWheel = onScrollWheel
        v.onMouseMoved = onMouseMoved
        v.onMouseExited = onMouseExited
        return v
    }

    func updateNSView(_ nsView: GraphMouseView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
        nsView.onScrollWheel = onScrollWheel
        nsView.onMouseMoved = onMouseMoved
        nsView.onMouseExited = onMouseExited
    }
}
#endif

// MARK: - WikiGraphView

struct WikiGraphView: View {
    /// Knowledge-base source override. nil = the Hermes home gateway
    /// (existing behavior); a Centaur session passes its wiki-api client so
    /// the same graph/browser/detail UI renders the Darkbloom KB.
    var overrideSource: (any WikiSource)?

    @StateObject private var viewModel = WikiGraphViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    /// Hermes-only chrome (wiki picker, taxonomy from wiki.list) hides when
    /// browsing an override source — those RPCs don't exist there.
    private var isOverride: Bool { overrideSource != nil }

    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragNodeIndex: Int?
    @State private var showWikiPicker = false
    @State private var lastPinchScale: CGFloat = 1.0

    private enum MouseState {
        case idle, deciding, panning, draggingNode
    }

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// Load through the override source when present, else the home gateway.
    /// `wiki` (multi-wiki selection) is Hermes-only and ignored on overrides.
    private func loadGraph(wiki: String?) async {
        if let overrideSource {
            await viewModel.load(source: overrideSource)
        } else {
            await viewModel.load(client: gatewayClientWrapper.client, wiki: wiki)
        }
    }

    private var viewMode: WikiViewMode { viewModel.viewMode }

    /// True for the force-directed graph modes (2D/3D), where the canvas,
    /// floating overlays, and physics timer apply. False for files/timeline.
    private var isGraphMode: Bool { viewMode == .twoD || viewMode == .threeD }

    /// Presents the shared reader as a sheet only where it is not already
    /// inline: files mode hosts it in the browser pane and macOS graph modes
    /// host it as a trailing side panel.
    private var readerSheetBinding: Binding<Bool> {
        Binding(
            get: {
                guard viewModel.showPageDetail, viewModel.selectedPath != nil else { return false }
                switch viewMode {
                case .files: return false
                case .timeline: return true
                case .twoD, .threeD:
                    #if os(macOS)
                    return false
                    #else
                    return true
                    #endif
                }
            },
            set: { viewModel.showPageDetail = $0 }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    if viewMode == .files {
                        // Files mode uses an in-flow toolbar; the floating
                        // graph overlays would cover the browser's sidebar.
                        VStack(spacing: 0) {
                            filesToolbar
                            Divider()
                            WikiBrowserView(viewModel: viewModel)
                        }
                    } else if viewMode == .timeline {
                        // Timeline mode reuses the in-flow toolbar pattern.
                        VStack(spacing: 0) {
                            filesToolbar
                            Divider()
                            WikiTimelineView(
                                wiki: viewModel.selectedWikiPath,
                                onOpenPage: { path in openPageFromTimeline(path) }
                            )
                        }
                    } else if viewMode == .threeD {
                        WikiGraph3DView(viewModel: viewModel)
                    } else {
                        graphCanvas

                        #if os(macOS)
                        GraphMouseInterceptor(
                            onMouseDown: { pt in handleMouseDown(pt) },
                            onMouseDragged: { pt in handleMouseDragged(pt) },
                            onMouseUp: { pt in handleMouseUp(pt) },
                            onScrollWheel: { delta in handleScrollWheel(delta) },
                            onMouseMoved: { pt in
                                if mouseState == .idle { viewModel.updateHover(at: pt) }
                            },
                            onMouseExited: { viewModel.clearHover() }
                        )
                        #else
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(iosDragGesture)
                        #endif
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(timer) { _ in
                    guard isGraphMode else { return }
                    guard viewModel.simAlpha > 0.003 || viewModel.simNodes.contains(where: { $0.isDragging }) else { return }
                    viewModel.tick()
                }
                .gesture(
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
                )

                if isGraphMode {
                    // macOS: the reader replaces the node-detail side panel
                    // inline; iOS presents it as a sheet instead.
                    #if os(macOS)
                    if viewModel.showPageDetail, viewModel.selectedPath != nil {
                        WikiReaderPane(
                            viewModel: viewModel,
                            onClose: { viewModel.showPageDetail = false },
                            showsShowInGraph: false
                        )
                        .frame(width: 400)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if let selIdx = viewModel.selectedNodeIndex,
                              viewModel.simNodes.indices.contains(selIdx) {
                        nodeDetailPanel(nodeIndex: selIdx)
                            .frame(width: 260)
                            .background(Theme.background)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    #else
                    if let selIdx = viewModel.selectedNodeIndex,
                       viewModel.simNodes.indices.contains(selIdx) {
                        nodeDetailPanel(nodeIndex: selIdx)
                            .frame(width: 260)
                            .background(Theme.background)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    #endif
                }
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.zoom) { _, _ in
            lastPinchScale = viewModel.zoom
        }
        .overlay(alignment: .topLeading) {
            if isGraphMode {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Wiki Graph")
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
        }
        .sheet(isPresented: $showWikiPicker) {
            WikiPathPickerSheet(
                selectedPath: $viewModel.selectedWikiPath,
                onSelect: { path in
                    Task { await loadGraph(wiki: path) }
                }
            )
        }
        .overlay(alignment: .topTrailing) {
            if isGraphMode {
                controlsOverlay
            }
        }
        .sheet(isPresented: readerSheetBinding) {
            WikiReaderPane(
                viewModel: viewModel,
                onClose: { viewModel.showPageDetail = false }
            )
            .frame(minWidth: 560, minHeight: 620)
        }
        .onAppear {
                Task {
                    await viewModel.discoverWikis(client: gatewayClientWrapper.client)
                    await loadGraph(wiki: viewModel.selectedWikiPath)
                }
        }
    }

    // MARK: - Mouse Event Handlers

    private func handleMouseDown(_ pt: CGPoint) {
        mouseState = .deciding
        dragStartPan = viewModel.panOffset
        dragStartPoint = pt
        dragNodeIndex = viewModel.hitTest(point: pt)
    }

    private func handleMouseDragged(_ pt: CGPoint) {
        let dx = pt.x - dragStartPoint.x
        let dy = pt.y - dragStartPoint.y
        let dist = hypot(dx, dy)

        switch mouseState {
        case .deciding:
            if dist > 5 {
                if let idx = dragNodeIndex {
                    mouseState = .draggingNode
                    viewModel.startDragging(index: idx, at: pt)
                } else {
                    mouseState = .panning
                }
            }
        case .panning:
            viewModel.panOffset = CGSize(
                width: dragStartPan.width + dx,
                height: dragStartPan.height + dy
            )
        case .draggingNode:
            if let idx = dragNodeIndex {
                viewModel.dragNode(index: idx, to: pt)
            }
        case .idle:
            break
        }
    }

    private func handleMouseUp(_ pt: CGPoint) {
        if mouseState == .deciding {
            viewModel.handleTap(at: dragStartPoint)
        }
        if let idx = dragNodeIndex {
            viewModel.stopDragging(index: idx)
        }
        mouseState = .idle
        dragNodeIndex = nil
    }

    private func handleScrollWheel(_ delta: CGSize) {
        viewModel.panOffset = CGSize(
            width: viewModel.panOffset.width + delta.width,
            height: viewModel.panOffset.height + delta.height
        )
    }

    #if !os(macOS)
    private var iosDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                switch mouseState {
                case .idle:
                    mouseState = .deciding
                    dragStartPan = viewModel.panOffset
                    dragStartPoint = value.startLocation
                    dragNodeIndex = viewModel.hitTest(point: value.startLocation)
                case .deciding:
                    let dist = hypot(value.translation.width, value.translation.height)
                    if dist > 5 {
                        if let idx = dragNodeIndex {
                            mouseState = .draggingNode
                            viewModel.startDragging(index: idx, at: value.location)
                        } else {
                            mouseState = .panning
                        }
                    }
                case .panning:
                    viewModel.panOffset = CGSize(
                        width: dragStartPan.width + value.translation.width,
                        height: dragStartPan.height + value.translation.height
                    )
                case .draggingNode:
                    if let idx = dragNodeIndex {
                        viewModel.dragNode(index: idx, to: value.location)
                    }
                }
            }
            .onEnded { value in
                if mouseState == .deciding {
                    viewModel.handleTap(at: value.startLocation)
                }
                if let idx = dragNodeIndex {
                    viewModel.stopDragging(index: idx)
                }
                mouseState = .idle
                dragNodeIndex = nil
            }
    }
    #endif

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let hasSelection = viewModel.highlightAnchor != nil
                let filtering = viewModel.isFiltering
                let filteredSet = viewModel.filteredNodeIndices

                context.translateBy(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
                context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

                // ── Curved edges ──
                for (si, ti) in viewModel.simLinks {
                    guard viewModel.simNodes.indices.contains(si),
                          viewModel.simNodes.indices.contains(ti) else { continue }

                    let isConnected = !hasSelection || viewModel.linkIsConnectedToSelection(si, ti)
                    let linkFilterMatch = !filtering || (filteredSet.contains(si) || filteredSet.contains(ti))
                    let opacity: CGFloat = isConnected ? (linkFilterMatch ? 0.55 : 0.06) : 0.06
                    let lineWidth: CGFloat = isConnected ? 1.6 : 0.5
                    let color = isConnected
                        ? Color(hex: "8a8aff")!.opacity(opacity)
                        : Theme.secondary.opacity(opacity)

                    let sp = viewModel.simNodes[si].position
                    let tp = viewModel.simNodes[ti].position

                    // Gentle quadratic curve: bow the line perpendicular to its
                    // direction for an organic, neural-network feel.
                    let mid = CGPoint(x: (sp.x + tp.x) / 2, y: (sp.y + tp.y) / 2)
                    let dx = tp.x - sp.x
                    let dy = tp.y - sp.y
                    let len = max(hypot(dx, dy), 1)
                    let bow: CGFloat = min(len * 0.12, 26)
                    let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)

                    var path = Path()
                    path.move(to: sp)
                    path.addQuadCurve(to: tp, control: ctrl)
                    context.stroke(path, with: .color(color), lineWidth: lineWidth)

                    if isConnected, hasSelection,
                       let selIdx = viewModel.selectedNodeIndex,
                       viewModel.simNodes.indices.contains(selIdx) {
                        let source = viewModel.simNodes[si]
                        let target = viewModel.simNodes[ti]
                        let labelText: String
                        if source.id == viewModel.simNodes[selIdx].id {
                            labelText = "→ \(target.label)"
                        } else if target.id == viewModel.simNodes[selIdx].id {
                            labelText = "← \(source.label)"
                        } else {
                            labelText = ""
                        }
                        if !labelText.isEmpty {
                            context.draw(
                                Text(labelText)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(hex: "8a8aff")!.opacity(0.7)),
                                at: ctrl, anchor: .center
                            )
                        }
                    }
                }

                // ── Nodes with radial glow + gradient ──
                let drawOrder = viewModel.simNodes.indices.sorted {
                    viewModel.simNodes[$0].position.y < viewModel.simNodes[$1].position.y
                }
                for index in drawOrder {
                    let node = viewModel.simNodes[index]
                    let isSelected = viewModel.selectedNodeIndex == index
                    let isHovered = viewModel.hoveredNodeIndex == index
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    let matchFilter = !filtering || filteredSet.contains(index)
                    let baseOpacity: CGFloat = isConnected ? (matchFilter ? 1.0 : 0.13) : 0.18
                    let r = viewModel.nodeRadius(at: index)
                    let base = viewModel.color(for: node.type)
                    let pos = node.position

                    // Glow halo
                    if isConnected {
                        let glowR = r * (isSelected || isHovered ? 3.4 : 2.4)
                        let glowRect = CGRect(x: pos.x - glowR, y: pos.y - glowR,
                                              width: glowR * 2, height: glowR * 2)
                        let glow = GraphicsContext.Shading.radialGradient(
                            Gradient(colors: [
                                base.opacity(isSelected || isHovered ? 0.45 : 0.22),
                                base.opacity(0)
                            ]),
                            center: pos, startRadius: 0, endRadius: glowR
                        )
                        context.fill(Path(ellipseIn: glowRect), with: glow)
                    }

                    // Selection / hover ring
                    if isSelected || isHovered {
                        let ringR = r + (isSelected ? 5 : 3)
                        let ringRect = CGRect(x: pos.x - ringR, y: pos.y - ringR,
                                              width: ringR * 2, height: ringR * 2)
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .color(.white.opacity(isSelected ? 0.85 : 0.5)),
                            lineWidth: isSelected ? 2 : 1.2
                        )
                    }

                    // Node body — radial gradient for depth
                    let nodeRect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                    let bodyShading = GraphicsContext.Shading.radialGradient(
                        Gradient(colors: [
                            base.opacity(baseOpacity),
                            base.opacity(baseOpacity * 0.62)
                        ]),
                        center: CGPoint(x: pos.x - r * 0.3, y: pos.y - r * 0.3),
                        startRadius: 0, endRadius: r * 1.4
                    )
                    context.fill(Path(ellipseIn: nodeRect), with: bodyShading)
                    context.stroke(
                        Path(ellipseIn: nodeRect),
                        with: .color(.white.opacity(isConnected ? 0.45 : 0.15)),
                        lineWidth: 0.8
                    )
                }

                // ── Labels (screen space, unscaled) ──
                context.transform = .identity
                let neighborSet = Set(viewModel.selectedNodeNeighbors())
                for (index, node) in viewModel.simNodes.enumerated() {
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    let matchesFilter = !filtering || filteredSet.contains(index)
                    guard isConnected && matchesFilter else { continue }
                    let isAnchor = viewModel.selectedNodeIndex == index || viewModel.hoveredNodeIndex == index
                    let isNeighbor = neighborSet.contains(index)
                    if viewModel.zoom < 0.7 && !isAnchor && !isNeighbor { continue }
                    let r = viewModel.nodeRadius(at: index)
                    let screenPos = CGPoint(
                        x: node.position.x * viewModel.zoom + viewModel.panOffset.width + r * viewModel.zoom + 4,
                        y: node.position.y * viewModel.zoom + viewModel.panOffset.height
                    )
                    guard screenPos.x > -50, screenPos.x < size.width + 50,
                          screenPos.y > -20, screenPos.y < size.height + 20 else { continue }
                    context.draw(
                        Text(node.label)
                            .font(.system(size: isAnchor ? 12 : 11,
                                          weight: isAnchor ? .semibold : .medium))
                            .foregroundColor(.white.opacity(isAnchor ? 1.0 : 0.82)),
                        at: screenPos, anchor: .leading
                    )
                }
            }
            .onAppear {
                viewModel.canvasSize = geo.size
                if geo.size != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                }
            }
            .onChange(of: geo.size) { _, newSize in
                viewModel.canvasSize = newSize
                if newSize != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                }
            }
        }
    }

    // MARK: - Node Detail Panel

    @ViewBuilder
    private func nodeDetailPanel(nodeIndex: Int) -> some View {
        let node = viewModel.simNodes[nodeIndex]
        let neighbors = viewModel.selectedNodeNeighbors()
        let page = viewModel.graph.pages.first(where: { $0.id == node.id })

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(node.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                Spacer()
                Button {
                    viewModel.deselectNode()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.color(for: node.type))
                    .frame(width: 8, height: 8)
                Text(node.type.capitalized)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            Divider()
                .padding(.vertical, 10)
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 8) {
                Text("Connected to \(neighbors.count) page(s)")
                    .font(.caption)
                    .foregroundStyle(Theme.primary)

                if let page = page {
                    if !page.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(page.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.surface, in: Capsule())
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }

                    if let confidence = page.confidence, !confidence.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.caption2)
                            Text("Confidence: \(confidence)")
                                .font(.caption2)
                        }
                        .foregroundStyle(Theme.secondary)
                    }

                    if page.contested {
                        Label("Contested", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(.horizontal, 14)

            Spacer()

            if let page = page {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        viewModel.navigate(to: page.path)
                        viewModel.openReaderForSelection()
                    } label: {
                        Label("Read Page", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.openInFiles(path: page.path)
                    } label: {
                        Label("Open in Files", systemImage: "list.bullet")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Legend

    @ViewBuilder
    private var legendView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Node Types")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            legendRow(color: "#7c7cff", label: "Entity", description: "things, people, tools")
            legendRow(color: "#5cb85c", label: "Concept", description: "ideas, patterns, abstractions")
            legendRow(color: "#e8a838", label: "Comparison", description: "contrasts, benchmarks, trade-offs")
            legendRow(color: "#ff6b9d", label: "Query", description: "questions, hypotheses, todos")
            legendRow(color: "#888888", label: "Raw", description: "unstructured notes")
        }
        .padding(8)
        .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func legendRow(color hex: String, label: String, description: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: hex)!)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.primary)
            Text("- \(description)")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Zoom Controls

    @ViewBuilder
    private var wikiPickerMenu: some View {
        Menu {
            Button("Default wiki") {
                viewModel.selectedWikiPath = nil
                Task { await loadGraph(wiki: nil) }
            }
            Divider()
            ForEach(viewModel.availableWikis, id: \.self) { wiki in
                Button(wiki) {
                    viewModel.selectedWikiPath = wiki
                    Task { await loadGraph(wiki: wiki) }
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

    @ViewBuilder
    private var filesToolbar: some View {
        HStack(spacing: 6) {
            Text("Wiki")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            if !isOverride { wikiPickerMenu }

            Text("\(viewModel.graph.pages.count) pages")
                .font(.caption)
                .foregroundStyle(Theme.secondary)

            Spacer()

            modeButton(.twoD, icon: "square.grid.2x2", help: "2D graph")
            modeButton(.threeD, icon: "cube.transparent", help: "3D graph")
            modeButton(.files, icon: "list.bullet", help: "File browser")
            modeButton(.timeline, icon: "clock.arrow.circlepath", help: "Timeline")

            Divider().frame(height: 14)

            Button {
                Task { await loadGraph(wiki: viewModel.selectedWikiPath) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        HStack(spacing: 6) {
            Button {
                let c = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                withAnimation(.easeOut(duration: 0.22)) {
                    viewModel.zoomAtPoint(factor: 0.8, around: c)
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Text("\(Int(viewModel.zoom * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 32)

            Button {
                let c = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                withAnimation(.easeOut(duration: 0.22)) {
                    viewModel.zoomAtPoint(factor: 1.25, around: c)
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    viewModel.resetView()
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            modeButton(.twoD, icon: "square.grid.2x2", help: "2D graph")
            modeButton(.threeD, icon: "cube.transparent", help: "3D graph")
            modeButton(.files, icon: "list.bullet", help: "File browser")
            modeButton(.timeline, icon: "clock.arrow.circlepath", help: "Timeline")

            Divider().frame(height: 14)

            Button {
            Task { await loadGraph(wiki: viewModel.selectedWikiPath) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.secondary)
        .padding(12)
    }

    @ViewBuilder
    private func modeButton(_ mode: WikiViewMode, icon: String, help: String) -> some View {
        Button {
            guard viewMode != mode else { return }
            viewModel.viewMode = mode
            if mode == .twoD || mode == .threeD {
                viewModel.is3D = mode == .threeD
                viewModel.setupSimulation()
                // Carry the shared page selection into the graph.
                viewModel.syncNodeSelection(toPath: viewModel.selectedPath)
                if mode == .twoD, let idx = viewModel.selectedNodeIndex {
                    viewModel.centerOnNode(idx)
                }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewMode == mode ? Theme.accent : Theme.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Open a wiki page from a timeline row tap through the shared selection
    /// plane: the page becomes the current page (history included) and the
    /// shared reader presents it. Pages not in the graph still load — the
    /// reader fetches by path.
    private func openPageFromTimeline(_ path: String) {
        viewModel.navigate(to: path)
        viewModel.openReaderForSelection()
    }
}
