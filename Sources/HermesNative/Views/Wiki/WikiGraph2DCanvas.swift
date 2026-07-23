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

// MARK: - WikiGraph2DCanvas

/// The force-directed 2D canvas: neural-style curved edges, glow nodes,
/// screen-space labels, and the platform input layer (NSView mouse
/// interception on macOS, DragGesture on iOS). Extracted from WikiGraphView
/// so the adaptive host stays a thin composition layer.
struct WikiGraph2DCanvas: View {
    @ObservedObject var viewModel: WikiGraphViewModel

    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragNodeIndex: Int?

    private enum MouseState {
        case idle, deciding, panning, draggingNode
    }

    var body: some View {
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

    // MARK: - Canvas Drawing

    private var canvas: some View {
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
}
