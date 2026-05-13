import SwiftUI

/// Native force-directed wiki graph using SwiftUI Canvas + TimelineView.
/// Adapted from rayfix/ForceDirectedGraph — pure Swift, no WebKit.
struct WikiGraphView: View {
    @StateObject private var viewModel = WikiGraphViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    @State private var isDragging = false
    @State private var draggingIndex: Int?
    @State private var isPanning = false
    @State private var panStart: CGPoint?

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                viewModel.canvasSize = size
                viewModel.tick()

                context.translateBy(x: viewModel.panOffset.width, y: viewModel.panOffset.height)
                context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

                // Draw links
                for (si, ti) in viewModel.simLinks {
                    guard viewModel.simNodes.indices.contains(si),
                          viewModel.simNodes.indices.contains(ti) else { continue }
                    let sp = viewModel.simNodes[si].position
                    let tp = viewModel.simNodes[ti].position
                    var path = Path()
                    path.move(to: sp)
                    path.addLine(to: tp)
                    context.stroke(path, with: .color(Color(hex: "7c7cff")!.opacity(0.35)), lineWidth: 1)
                }

                // Draw nodes
                for node in viewModel.simNodes {
                    let ellipse = CGRect(
                        x: node.position.x - viewModel.nodeRadius(for: node.type),
                        y: node.position.y - viewModel.nodeRadius(for: node.type),
                        width: viewModel.nodeRadius(for: node.type) * 2,
                        height: viewModel.nodeRadius(for: node.type) * 2
                    )
                    context.fill(Path(ellipseIn: ellipse), with: .color(viewModel.color(for: node.type)))
                    // White stroke
                    context.stroke(Path(ellipseIn: ellipse), with: .color(.white.opacity(0.3)), lineWidth: 1)
                }

                // Draw labels (always readable, not scaled)
                context.transform = .identity
                for node in viewModel.simNodes {
                    let screenPos = CGPoint(
                        x: node.position.x * viewModel.zoom + viewModel.panOffset.width + 10,
                        y: node.position.y * viewModel.zoom + viewModel.panOffset.height + 4
                    )
                    // Only draw if on screen (with some margin)
                    if screenPos.x > -50 && screenPos.x < size.width + 50 &&
                       screenPos.y > -20 && screenPos.y < size.height + 20 {
                        context.draw(
                            Text(node.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.85)),
                            at: screenPos,
                            anchor: .leading
                        )
                    }
                }
            }
            .gesture(dragGesture)
            .gesture(magnificationGesture)
        }
        .background(Theme.background)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wiki Graph")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Text("\(viewModel.graph.pages.count) pages · \(viewModel.graph.links.count) links")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(10)
            .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption2)
                }
            }
            .foregroundStyle(Theme.secondary)
            .padding(8)
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await viewModel.load(client: gatewayClientWrapper.client) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondary)
            .padding(12)
            .help("Refresh graph")
        }
        .sheet(isPresented: $viewModel.showPageDetail) {
            if let page = viewModel.selectedPage {
                WikiPageDetailView(page: page, viewModel: viewModel)
                    .frame(minWidth: 560, minHeight: 620)
            }
        }
        .onAppear {
            Task { await viewModel.load(client: gatewayClientWrapper.client) }
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                if isDragging, let index = draggingIndex {
                    viewModel.dragNode(index: index, to: drag.location)
                } else if isPanning, let start = panStart {
                    viewModel.panOffset = CGSize(
                        width: drag.location.x - start.x,
                        height: drag.location.y - start.y
                    )
                } else {
                    // Determine if we're hitting a node or background
                    if let index = viewModel.hitTest(point: drag.location) {
                        isDragging = true
                        draggingIndex = index
                        viewModel.startDragging(index: index, at: drag.location)
                    } else {
                        isPanning = true
                        panStart = CGPoint(
                            x: drag.location.x - viewModel.panOffset.width,
                            y: drag.location.y - viewModel.panOffset.height
                        )
                    }
                }
            }
            .onEnded { _ in
                if let index = draggingIndex {
                    viewModel.stopDragging(index: index)
                }
                isDragging = false
                draggingIndex = nil
                isPanning = false
                panStart = nil
            }
    }

    #if os(macOS)
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                // Use center of view as zoom anchor
                let center = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: scale, around: center)
            }
    }
    #else
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let center = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: scale, around: center)
            }
    }
    #endif
}
