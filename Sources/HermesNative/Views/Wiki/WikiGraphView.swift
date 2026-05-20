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
}

/// SwiftUI wrapper for GraphMouseView.
struct GraphMouseInterceptor: NSViewRepresentable {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> GraphMouseView {
        let v = GraphMouseView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        return v
    }

    func updateNSView(_ nsView: GraphMouseView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
    }
}
#endif

// MARK: - WikiGraphView

struct WikiGraphView: View {
    @StateObject private var viewModel = WikiGraphViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragNodeIndex: Int?
    @State private var showWikiPicker = false

    private enum MouseState {
        case idle, deciding, panning, draggingNode
    }

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    graphCanvas

                    #if os(macOS)
                    GraphMouseInterceptor(
                        onMouseDown: { pt in handleMouseDown(pt) },
                        onMouseDragged: { pt in handleMouseDragged(pt) },
                        onMouseUp: { pt in handleMouseUp(pt) }
                    )
                    #else
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(iosDragGesture)
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(timer) { _ in
                    viewModel.tick()
                }

                if let selIdx = viewModel.selectedNodeIndex,
                   viewModel.simNodes.indices.contains(selIdx) {
                    nodeDetailPanel(nodeIndex: selIdx)
                        .frame(width: 260)
                        .background(Theme.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Wiki Graph")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)

                    // Wiki selector
                    Menu {
                        Button("Default wiki") {
                            viewModel.selectedWikiPath = nil
                            Task { await viewModel.load(client: gatewayClientWrapper.client, wiki: nil) }
                        }
                        Divider()
                        ForEach(viewModel.availableWikis, id: \.self) { wiki in
                            Button(wiki) {
                                viewModel.selectedWikiPath = wiki
                                Task { await viewModel.load(client: gatewayClientWrapper.client, wiki: wiki) }
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
                Text("\(viewModel.graph.pages.count) pages · \(viewModel.graph.links.count) links")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(10)
            .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .sheet(isPresented: $showWikiPicker) {
            WikiPathPickerSheet(
                selectedPath: $viewModel.selectedWikiPath,
                onSelect: { path in
                    Task { await viewModel.load(client: gatewayClientWrapper.client, wiki: path) }
                }
            )
        }
        .overlay(alignment: .topTrailing) {
            controlsOverlay
        }
        .sheet(isPresented: $viewModel.showPageDetail) {
            if let page = viewModel.selectedPage {
                WikiPageDetailView(page: page, viewModel: viewModel)
                    .frame(minWidth: 560, minHeight: 620)
            }
        }
        .onAppear {
                Task { await viewModel.load(client: gatewayClientWrapper.client, wiki: viewModel.selectedWikiPath) }
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
        GeometryReader { geometry in
            Canvas { context, size in
                let wasZero = viewModel.canvasSize == .zero
                viewModel.canvasSize = size
                if wasZero && size != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.pages.isEmpty {
                    viewModel.setupSimulation()
                }

                let hasSelection = viewModel.selectedNodeIndex != nil

                context.translateBy(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
                context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

                for (si, ti) in viewModel.simLinks {
                    guard viewModel.simNodes.indices.contains(si),
                          viewModel.simNodes.indices.contains(ti) else { continue }

                    let isConnected = !hasSelection || viewModel.linkIsConnectedToSelection(si, ti)
                    let opacity: CGFloat = isConnected ? 0.5 : 0.08
                    let lineWidth: CGFloat = isConnected ? 1.5 : 0.5
                    let color = isConnected
                        ? Color(hex: "7c7cff")!.opacity(opacity)
                        : Theme.secondary.opacity(opacity)

                    let sp = viewModel.simNodes[si].position
                    let tp = viewModel.simNodes[ti].position
                    var path = Path()
                    path.move(to: sp)
                    path.addLine(to: tp)
                    context.stroke(path, with: .color(color), lineWidth: lineWidth)

                    if isConnected, hasSelection,
                       viewModel.simNodes.indices.contains(si),
                       viewModel.simNodes.indices.contains(ti),
                       let selIdx = viewModel.selectedNodeIndex {
                        let mid = CGPoint(x: (sp.x + tp.x) / 2, y: (sp.y + tp.y) / 2)
                        let source = viewModel.simNodes[si]
                        let target = viewModel.simNodes[ti]
                        let labelText: String
                        if source.id == viewModel.simNodes[selIdx].id {
                            labelText = "→ \(target.label)"
                        } else {
                            labelText = "← \(source.label)"
                        }
                        context.draw(
                            Text(labelText)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color(hex: "7c7cff")!.opacity(0.7)),
                            at: mid, anchor: .center
                        )
                    }
                }

                let sorted = viewModel.simNodes.enumerated().sorted { (a, b) in
                    a.element.position.y < b.element.position.y
                }
                for (index, node) in sorted {
                    let isSelected = viewModel.selectedNodeIndex == index
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    let baseOpacity = isConnected ? 1.0 : 0.2
                    let r = viewModel.nodeRadius(for: node.type)
                    let ellipse = CGRect(x: node.position.x - r, y: node.position.y - r,
                                         width: r * 2, height: r * 2)

                    if isSelected {
                        let ringRect = CGRect(x: node.position.x - r - 4,
                                               y: node.position.y - r - 4,
                                               width: r * 2 + 8, height: r * 2 + 8)
                        context.fill(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.3)))
                    }

                    context.fill(Path(ellipseIn: ellipse),
                                 with: .color(viewModel.color(for: node.type).opacity(baseOpacity)))
                    context.stroke(Path(ellipseIn: ellipse),
                                   with: .color(.white.opacity(isSelected ? 0.8 : 0.3)))
                }

                context.transform = .identity
                for (index, node) in viewModel.simNodes.enumerated() {
                    let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
                    guard isConnected else { continue }
                    let screenPos = CGPoint(
                        x: node.position.x * viewModel.zoom + viewModel.panOffset.width + 10,
                        y: node.position.y * viewModel.zoom + viewModel.panOffset.height + 4
                    )
                    guard screenPos.x > -50, screenPos.x < size.width + 50,
                          screenPos.y > -20, screenPos.y < size.height + 20 else { continue }
                    context.draw(
                        Text(node.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85)),
                        at: screenPos, anchor: .leading
                    )
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

            if page != nil {
                Button {
                    viewModel.selectedPage = page
                    viewModel.showPageDetail = true
                } label: {
                    Label("Open Page Detail", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
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
    private var controlsOverlay: some View {
        HStack(spacing: 6) {
            Button {
                let c = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: 0.8, around: c)
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
                viewModel.zoomAtPoint(factor: 1.25, around: c)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                viewModel.resetView()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            Button {
            Task { await viewModel.load(client: gatewayClientWrapper.client, wiki: viewModel.selectedWikiPath) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.secondary)
        .padding(12)
    }
}
