import SwiftUI

/// Interactive force-directed explorer for diagram-derived graphs
/// (e.g. mermaid flowcharts / mindmaps converted via MermaidGraphParser).
/// Designed to be presented in a sheet.
struct DiagramExplorerView: View {
    let graph: WikiGraph
    let title: String

    @StateObject private var viewModel = WikiGraphViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragNodeIndex: Int?
    @State private var lastPinchScale: CGFloat = 1.0
    @State private var is3DMode = false

    private enum MouseState {
        case idle, deciding, panning, draggingNode
    }

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    init(graph: WikiGraph, title: String) {
        self.graph = graph
        self.title = title
    }

    init?(mermaidSource: String, title: String) {
        guard let parsed = MermaidGraphParser.parse(mermaidSource) else { return nil }
        self.graph = parsed
        self.title = title
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                graphArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let selIdx = viewModel.selectedNodeIndex,
                   viewModel.simNodes.indices.contains(selIdx) {
                    Divider()
                    selectionPanel(nodeIndex: selIdx)
                        .frame(width: 240)
                        .background(Theme.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.background)
        .frame(minWidth: 640, minHeight: 480)
        .onReceive(timer) { _ in
            guard viewModel.simAlpha > 0.003 || viewModel.simNodes.contains(where: { $0.isDragging }) else { return }
            viewModel.tick()
        }
        .onChange(of: viewModel.zoom) { _, _ in
            lastPinchScale = viewModel.zoom
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text("\(graph.pages.count) nodes · \(graph.links.count) edges")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Spacer()

            Button {
                is3DMode.toggle()
                viewModel.is3D = is3DMode
                viewModel.setupSimulation()
            } label: {
                Image(systemName: is3DMode ? "square.grid.2x2" : "cube.transparent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.borderless)
            .help(is3DMode ? "Switch to 2D" : "Switch to 3D")

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.resetView()
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reset view")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    // MARK: - Graph Area

    private var graphArea: some View {
        GeometryReader { geo in
            ZStack {
                if is3DMode {
                    WikiGraph3DView(viewModel: viewModel)
                } else {
                    graphCanvas

                    #if os(macOS)
                    GraphMouseInterceptor(
                        onMouseDown: { pt in handleMouseDown(pt) },
                        onMouseDragged: { pt in handleMouseDragged(pt) },
                        onMouseUp: { pt in handleMouseUp(pt) },
                        onScrollWheel: { delta in
                            viewModel.panOffset = CGSize(
                                width: viewModel.panOffset.width + delta.width,
                                height: viewModel.panOffset.height + delta.height
                            )
                        },
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
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let clamped = max(0.3, min(5.0, lastPinchScale * value))
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
            .onAppear {
                viewModel.graph = graph
                viewModel.canvasSize = geo.size
                if geo.size != .zero {
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

    // MARK: - Canvas (2D)

    private var graphCanvas: some View {
        Canvas { context, size in
            let hasSelection = viewModel.highlightAnchor != nil

            context.translateBy(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
            context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

            // Curved edges
            for (si, ti) in viewModel.simLinks {
                guard viewModel.simNodes.indices.contains(si),
                      viewModel.simNodes.indices.contains(ti) else { continue }

                let isConnected = !hasSelection || viewModel.linkIsConnectedToSelection(si, ti)
                let opacity: CGFloat = isConnected ? 0.55 : 0.06
                let lineWidth: CGFloat = isConnected ? 1.6 : 0.5
                let color = isConnected
                    ? (Color(hex: "8a8aff") ?? Theme.accent).opacity(opacity)
                    : Theme.secondary.opacity(opacity)

                let sp = viewModel.simNodes[si].position
                let tp = viewModel.simNodes[ti].position

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
                                .foregroundColor((Color(hex: "8a8aff") ?? Theme.accent).opacity(0.7)),
                            at: ctrl, anchor: .center
                        )
                    }
                }
            }

            // Nodes with glow + gradient
            let drawOrder = viewModel.simNodes.indices.sorted {
                viewModel.simNodes[$0].position.y < viewModel.simNodes[$1].position.y
            }
            for index in drawOrder {
                let node = viewModel.simNodes[index]
                let isSelected = viewModel.selectedNodeIndex == index
                let isHovered = viewModel.hoveredNodeIndex == index
                let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                let baseOpacity: CGFloat = isConnected ? 1.0 : 0.18
                let r = viewModel.nodeRadius(at: index)
                let base = Self.typeColor(node.type)
                let pos = node.position

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

            // Labels (screen space, unscaled; culled at low zoom)
            context.transform = .identity
            let neighborSet = Set(viewModel.selectedNodeNeighbors())
            for (index, node) in viewModel.simNodes.enumerated() {
                let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                guard isConnected else { continue }
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
    }

    // MARK: - Mouse handling (macOS)

    #if os(macOS)
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
    #else
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

    // MARK: - Selection Panel

    @ViewBuilder
    private func selectionPanel(nodeIndex: Int) -> some View {
        let node = viewModel.simNodes[nodeIndex]
        let neighbors = viewModel.selectedNodeNeighbors()

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(node.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(3)
                Spacer()
                Button {
                    viewModel.deselectNode()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack(spacing: 6) {
                Circle()
                    .fill(Self.typeColor(node.type))
                    .frame(width: 8, height: 8)
                Text(node.type.capitalized)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.surfaceHover, in: Capsule())
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Divider()
                .padding(.vertical, 10)
                .padding(.horizontal, 14)

            Text("Connected (\(neighbors.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(neighbors, id: \.self) { neighborIndex in
                        if viewModel.simNodes.indices.contains(neighborIndex) {
                            let neighbor = viewModel.simNodes[neighborIndex]
                            Button {
                                viewModel.selectedNodeIndex = neighborIndex
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Self.typeColor(neighbor.type))
                                        .frame(width: 6, height: 6)
                                    Text(neighbor.label)
                                        .font(.callout)
                                        .foregroundStyle(Theme.primary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Type Colors

    /// Fixed colors for mindmap depth types; stable hashed hue for arbitrary
    /// flowchart subgraph types.
    static func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "root":
            return Color(hue: 0.08, saturation: 0.70, brightness: 0.95)
        case "branch":
            return Color(hue: 0.55, saturation: 0.55, brightness: 0.88)
        case "leaf":
            return Color(hue: 0.36, saturation: 0.50, brightness: 0.82)
        default:
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in type.lowercased().utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            let hue = Double(hash % 360) / 360.0
            return Color(hue: hue, saturation: 0.55, brightness: 0.85)
        }
    }
}
