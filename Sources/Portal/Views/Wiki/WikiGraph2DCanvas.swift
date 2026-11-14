import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Mouse Interceptor (NSView)

/// A transparent NSView that captures mouseDown / mouseDragged / mouseUp
/// and forwards them as callbacks.  This bypasses the broken SwiftUI
/// DragGesture-on-Canvas path on macOS.
internal final class GraphMouseView: NSView {
    internal var onMouseDown: ((CGPoint) -> Void)?
    internal var onMouseDragged: ((CGPoint) -> Void)?
    internal var onMouseUp: ((CGPoint) -> Void)?
    internal var onScrollWheel: ((CGSize) -> Void)?
    internal var onMouseMoved: ((CGPoint) -> Void)?
    internal var onMouseExited: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override internal init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    internal required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override internal var isFlipped: Bool { true }
    override internal func hitTest(_ point: NSPoint) -> NSView? { self }
    override internal func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override internal var acceptsFirstResponder: Bool { true }

    override internal func updateTrackingAreas() {
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

    override internal func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseDown?(pt)
    }

    override internal func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseDragged?(pt)
    }

    override internal func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseUp?(pt)
    }

    override internal func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onMouseMoved?(pt)
    }

    override internal func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override internal func scrollWheel(with event: NSEvent) {
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        onScrollWheel?(delta)
    }
}

/// SwiftUI wrapper for GraphMouseView.
internal struct GraphMouseInterceptor: NSViewRepresentable {
    internal var onMouseDown: ((CGPoint) -> Void)?
    internal var onMouseDragged: ((CGPoint) -> Void)?
    internal var onMouseUp: ((CGPoint) -> Void)?
    internal var onScrollWheel: ((CGSize) -> Void)?
    internal var onMouseMoved: ((CGPoint) -> Void)?
    internal var onMouseExited: (() -> Void)?

    internal func makeNSView(context: Context) -> GraphMouseView {
        let v = GraphMouseView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onScrollWheel = onScrollWheel
        v.onMouseMoved = onMouseMoved
        v.onMouseExited = onMouseExited
        return v
    }

    internal func updateNSView(_ nsView: GraphMouseView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
        nsView.onScrollWheel = onScrollWheel
        nsView.onMouseMoved = onMouseMoved
        nsView.onMouseExited = onMouseExited
    }
}
#endif

// MARK: - WikiGraph2DCanvas

/// The force-directed 2D canvas: neural-style curved edges, glow nodes,
/// screen-space labels, and the platform input layer (NSView mouse
/// interception on macOS, DragGesture on iOS). Extracted from WikiGraphView
/// so the adaptive host stays a thin composition layer.
internal struct WikiGraph2DCanvas: View {
    @ObservedObject internal var viewModel: WikiGraphViewModel
    /// The per-frame state (positions, painter's order, hover, camera). This
    /// canvas is the only wiki view that observes it, so a physics frame or a
    /// hovered node redraws the canvas and nothing else on the surface.
    @ObservedObject internal var simulation: WikiSimulationStore

    /// Labels drawn per frame beyond the anchor and its neighbours, by zoom:
    /// zoomed out a 5k graph would otherwise queue thousands of Text draws.
    internal static func labelCap(zoom: CGFloat) -> Int { zoom < 1.0 ? 200 : 600 }

    internal init(viewModel: WikiGraphViewModel) {
        self.viewModel = viewModel
        self.simulation = viewModel.simulation
    }

    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragNodeIndex: Int?

    private enum MouseState {
        case idle, deciding, panning, draggingNode
    }

    internal var body: some View {
        let _ = PerfCounter.tick("view.body.WikiGraph2DCanvas")
        ZStack {
            canvas

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

    // MARK: - Mouse Event Handlers

    private func handleMouseDown(_ pt: CGPoint) {
        mouseState = .deciding
        dragStartPan = simulation.panOffset
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
            simulation.panOffset = CGSize(
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
        simulation.noteInteraction()
        simulation.panOffset = CGSize(
            width: simulation.panOffset.width + delta.width,
            height: simulation.panOffset.height + delta.height
        )
    }

    #if !os(macOS)
    private var iosDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                switch mouseState {
                case .idle:
                    mouseState = .deciding
                    dragStartPan = simulation.panOffset
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
                    simulation.panOffset = CGSize(
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

    // MARK: - Canvas Drawing

    private var canvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let hasSelection = viewModel.highlightAnchor != nil
                let filtering = viewModel.isFiltering
                let filteredSet = viewModel.filteredNodeIndices
                let zoom = simulation.zoom
                let pan = simulation.panOffset
                let positions = simulation.positions
                let meta = viewModel.nodeMeta
                let hovered = simulation.hoveredNodeIndex
                let selected = viewModel.selectedNodeIndex
                // The camera or cursor is moving — click-drag/pan (tracked here)
                // or hover/pinch/scroll (tracked on the store). Draw a cheaper
                // frame while it holds: the ambient per-node glow and gradient
                // body fills are the dominant per-frame cost on a large graph,
                // and they're imperceptible mid-motion. Full fidelity returns at rest.
                let interacting = mouseState == .panning || mouseState == .draggingNode
                    || simulation.isInteracting

                // Visible world rect, padded past the largest node glow, for
                // culling — off-screen nodes/edges cost nothing.
                let cullPad: CGFloat = 90
                let visibleWorld = CGRect(
                    x: -pan.width / zoom - cullPad,
                    y: -pan.height / zoom - cullPad,
                    width: size.width / zoom + cullPad * 2,
                    height: size.height / zoom + cullPad * 2
                )

                context.translateBy(x: pan.width, y: pan.height)
                context.scaleBy(x: zoom, y: zoom)

                // ── Curved edges, BATCHED into one path per style bucket ──
                // (hundreds of individual strokes were a large share of the
                // per-frame cost on big graphs; same visual result).
                var litEdges = Path()
                var dimEdges = Path()
                var quietEdges = Path()
                let edgeLabelColor = (Color(hex: "8a8aff") ?? Theme.accent)
                for (linkIndex, (si, ti)) in viewModel.simLinks.enumerated() {
                    guard positions.indices.contains(si), positions.indices.contains(ti) else { continue }

                    let sp = positions[si]
                    let tp = positions[ti]
                    // Cull edges with both endpoints off-screen.
                    if !visibleWorld.contains(sp) && !visibleWorld.contains(tp) { continue }

                    let isConnected = !hasSelection || viewModel.linkIsConnectedToSelection(si, ti)
                    let linkFilterMatch = !filtering || (filteredSet.contains(si) || filteredSet.contains(ti))

                    // Gentle quadratic curve: bow the line perpendicular to its
                    // direction for an organic, neural-network feel.
                    let mid = CGPoint(x: (sp.x + tp.x) / 2, y: (sp.y + tp.y) / 2)
                    let dx = tp.x - sp.x
                    let dy = tp.y - sp.y
                    let len = max(hypot(dx, dy), 1)
                    let bow: CGFloat = min(len * 0.12, 26)
                    let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)

                    if isConnected, linkFilterMatch {
                        litEdges.move(to: sp)
                        litEdges.addQuadCurve(to: tp, control: ctrl)
                    } else if isConnected {
                        dimEdges.move(to: sp)
                        dimEdges.addQuadCurve(to: tp, control: ctrl)
                    } else {
                        quietEdges.move(to: sp)
                        quietEdges.addQuadCurve(to: tp, control: ctrl)
                    }

                    // A typed link ([[target|deployed-on]]) renders its
                    // relationship on the edge whenever the edge is lit — that's
                    // the whole point of an aliased link. Plain links keep the
                    // old on-selection behaviour: label the neighbour's title.
                    let relationLabel = linkIndex < viewModel.simLinkLabels.count
                        ? viewModel.simLinkLabels[linkIndex] : nil
                    if let relationLabel, !relationLabel.isEmpty, isConnected, linkFilterMatch {
                        context.draw(
                            Text(relationLabel)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(edgeLabelColor.opacity(0.85)),
                            at: ctrl, anchor: .center
                        )
                    } else if isConnected, hasSelection, let selIdx = selected,
                              meta.indices.contains(selIdx), meta.indices.contains(si), meta.indices.contains(ti) {
                        let labelText: String
                        if si == selIdx {
                            labelText = "→ \(meta[ti].label)"
                        } else if ti == selIdx {
                            labelText = "← \(meta[si].label)"
                        } else {
                            labelText = ""
                        }
                        if !labelText.isEmpty {
                            context.draw(
                                Text(labelText)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(edgeLabelColor.opacity(0.7)),
                                at: ctrl, anchor: .center
                            )
                        }
                    }
                }
                context.stroke(
                    litEdges,
                    with: .color(edgeLabelColor.opacity(0.55)),
                    lineWidth: 1.6
                )
                context.stroke(
                    dimEdges,
                    with: .color(edgeLabelColor.opacity(0.06)),
                    lineWidth: 1.6
                )
                context.stroke(
                    quietEdges,
                    with: .color(Theme.secondary.opacity(0.06)),
                    lineWidth: 0.5
                )

                // ── Nodes with radial glow + gradient ──
                // Painter's order comes from the store's cached drawOrder —
                // recomputed only when positions change, never per frame.
                for index in simulation.drawOrder {
                    guard positions.indices.contains(index), meta.indices.contains(index) else { continue }
                    let pos = positions[index]
                    // Cull off-screen nodes.
                    guard visibleWorld.contains(pos) else { continue }
                    let isSelected = selected == index
                    let isHovered = hovered == index
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    let matchFilter = !filtering || filteredSet.contains(index)
                    let baseOpacity: CGFloat = isConnected ? (matchFilter ? 1.0 : 0.13) : 0.18
                    let r = viewModel.nodeRadius(at: index)
                    let base = viewModel.color(forNode: meta[index])

                    // Glow halo — an expensive radial gradient per node. At rest
                    // every connected node carries one (the neural-glow look);
                    // mid-motion only the hovered/selected anchor keeps its glow
                    // so a large graph doesn't repaint hundreds of gradients a
                    // frame while the camera moves.
                    if isConnected && (!interacting || isSelected || isHovered) {
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

                    // Node body — a radial gradient for depth at rest; a flat
                    // fill mid-motion (one more per-node gradient dropped while
                    // the camera moves, restored the instant it stops).
                    let nodeRect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                    let bodyShading: GraphicsContext.Shading = interacting
                        ? .color(base.opacity(baseOpacity))
                        : .radialGradient(
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
                // Skipped while the camera or cursor moves — click-drag/pan,
                // hover, pinch-zoom, scroll-pan: hundreds of Text draws are the
                // priciest pass per frame, and labels only matter once motion
                // stops, so they pop back a beat after the last move. Only the
                // nodes in the grid cells under the viewport are candidates,
                // and beyond the anchor + its neighbours the pass is capped.
                guard !interacting else { return }
                context.transform = .identity
                let neighborSet: Set<Int> = hasSelection ? Set(viewModel.selectedNodeNeighbors()) : []
                let labelCap = Self.labelCap(zoom: zoom)
                var drawnLabels = 0
                for index in simulation.indices(in: visibleWorld) {
                    guard meta.indices.contains(index), positions.indices.contains(index) else { continue }
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    let matchesFilter = !filtering || filteredSet.contains(index)
                    guard isConnected && matchesFilter else { continue }
                    let isAnchor = selected == index || hovered == index
                    let isNeighbor = neighborSet.contains(index)
                    if !isAnchor && !isNeighbor {
                        if zoom < 0.7 || drawnLabels >= labelCap { continue }
                        drawnLabels += 1
                    }
                    let r = viewModel.nodeRadius(at: index)
                    let position = positions[index]
                    let screenPos = CGPoint(
                        x: position.x * zoom + pan.width + r * zoom + 4,
                        y: position.y * zoom + pan.height
                    )
                    guard screenPos.x > -50, screenPos.x < size.width + 50,
                          screenPos.y > -20, screenPos.y < size.height + 20 else { continue }
                    context.draw(
                        Text(meta[index].label)
                            .font(.system(size: isAnchor ? 12 : 11,
                                          weight: isAnchor ? .semibold : .medium))
                            .foregroundColor(.white.opacity(isAnchor ? 1.0 : 0.82)),
                        at: screenPos, anchor: .leading
                    )
                }
            }
            .onAppear {
                viewModel.canvasSize = geo.size
                if geo.size != .zero && viewModel.nodeMeta.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                } else {
                    // Preloaded graph (settled in the background against the
                    // nominal size): frame it once for this real canvas.
                    viewModel.refitForFirstDisplayIfNeeded()
                }
            }
            .onChange(of: geo.size) { _, newSize in
                viewModel.canvasSize = newSize
                if newSize != .zero && viewModel.nodeMeta.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                } else {
                    viewModel.refitForFirstDisplayIfNeeded()
                }
            }
        }
    }
}
