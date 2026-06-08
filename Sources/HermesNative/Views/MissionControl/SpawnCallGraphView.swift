import SwiftUI

/// Canvas-based call graph showing the spawn tree as a node-edge hierarchy.
struct SpawnCallGraphView: View {
    let root: SpawnNode
    @Binding var selectedNodeID: String?
    let onNodeTap: (SpawnNode) -> Void

    private let nodeRadius: CGFloat = 26
    private let verticalGap: CGFloat = 64
    private let horizontalGap: CGFloat = 52

    @State private var hoveredNodeID: String?

    var body: some View {
        GeometryReader { proxy in
            let layout = computeLayout(width: proxy.size.width)
            Canvas { context, size in
                // Edges
                let edgeColor = Color.secondary.opacity(0.35)
                for (from, to) in layout.edges {
                    let a = layout.positions[from]!
                    let b = layout.positions[to]!
                    var path = Path()
                    path.move(to: a)
                    // Slight curve for visual appeal
                    let midY = (a.y + b.y) / 2
                    path.addLine(to: CGPoint(x: a.x, y: midY))
                    path.addLine(to: CGPoint(x: b.x, y: midY))
                    path.addLine(to: b)
                    context.stroke(path, with: .color(edgeColor), lineWidth: 1.2)
                }

                // Nodes
                for (id, pos) in layout.positions.sorted(by: { $0.value.y < $1.value.y }) {
                    let node = layout.nodeMap[id]!
                    let sel = selectedNodeID == id
                    let hov = hoveredNodeID == id
                    let r = sel || hov ? nodeRadius + 3 : nodeRadius
                    let statusColor = colorForStatus(node.status)

                    // Glow for selected/hovered
                    if sel || hov {
                        let glowRect = CGRect(x: pos.x - r - 6, y: pos.y - r - 6,
                                              width: (r + 6) * 2, height: (r + 6) * 2)
                        context.fill(
                            Path(ellipseIn: glowRect),
                            with: .radialGradient(
                                Gradient(stops: [
                                    .init(color: statusColor.opacity(0.35), location: 0),
                                    .init(color: statusColor.opacity(0), location: 1),
                                ]),
                                center: CGPoint(x: glowRect.midX, y: glowRect.midY),
                                startRadius: 0,
                                endRadius: r + 6
                            )
                        )
                    }

                    // Node body
                    let bodyColor: Color = {
                        if let hovID = hoveredNodeID, hovID != id {
                            return sel || hov ? statusColor : statusColor.opacity(0.25)
                        }
                        return statusColor.opacity(0.85)
                    }()
                    let circleRect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: circleRect), with: .color(bodyColor))
                    context.stroke(Path(ellipseIn: circleRect), with: .color(statusColor.opacity(0.9)), lineWidth: sel || hov ? 2 : 1)

                    // Count badge inside node
                    let countText = "\(node.children.count)"
                    let _ = context.resolve(Text(countText).font(.system(size: 10, weight: .bold)).foregroundColor(.white))
                        .measure(in: CGSize(width: 100, height: 20))
                    context.draw(
                        Text(countText).font(.system(size: 10, weight: .bold)).foregroundColor(.white),
                        at: CGPoint(x: pos.x, y: pos.y), anchor: .center
                    )

                    // Label below
                    let goal = String(node.goal.prefix(40))
                    let label = goal.isEmpty ? "Root prompt" : goal
                    context.draw(
                        Text(label).font(.system(size: 9, weight: sel ? .semibold : .regular)).foregroundColor(.white.opacity(sel ? 1.0 : 0.7)),
                        in: CGRect(x: pos.x - 60, y: pos.y + r + 4, width: 120, height: 24),
                        alignCenter: true
                    )
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let pt = value.location
                        for (id, pos) in layout.positions {
                            let dist = hypot(pt.x - pos.x, pt.y - pos.y)
                            if dist <= nodeRadius + 8 {
                                selectedNodeID = id
                                if let node = layout.nodeMap[id] {
                                    onNodeTap(node)
                                }
                                return
                            }
                        }
                        selectedNodeID = nil
                    }
            )
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    for (id, pos) in layout.positions where hypot(pt.x - pos.x, pt.y - pos.y) <= nodeRadius + 8 {
                            hoveredNodeID = id
                            return
                        }
                        hoveredNodeID = nil
                case .ended:
                    hoveredNodeID = nil
                }
            }
            #endif
        }
        .frame(minHeight: max(CGFloat(maxLeafCount(root) * 60), 400))
    }

    // MARK: - Layout computation

    private struct LayoutResult {
        var positions: [String: CGPoint] = [:]
        var edges: [(String, String)] = []
        var nodeMap: [String: SpawnNode] = [:]
    }

    private func computeLayout(width: CGFloat) -> LayoutResult {
        var result = LayoutResult()

        // Collect all nodes
        var allNodes: [SpawnNode] = []
        func collect(_ node: SpawnNode) {
            allNodes.append(node)
            result.nodeMap[node.id] = node
            for child in node.children {
                result.edges.append((node.id, child.id))
                collect(child)
            }
        }
        collect(root)

        // Compute subtree widths for horizontal positioning
        func subtreeWidth(_ node: SpawnNode) -> Int {
            if node.children.isEmpty { return 1 }
            return node.children.reduce(0) { $0 + subtreeWidth($1) }
        }

        let startY: CGFloat = 40
        func positionNode(_ node: SpawnNode, x: CGFloat, y: CGFloat, available: CGFloat) {
            result.positions[node.id] = CGPoint(x: x + available / 2, y: y)

            if node.children.isEmpty { return }
            let childY = y + verticalGap
            let childAvailable = available / CGFloat(node.children.count)
            for (i, child) in node.children.enumerated() {
                let cx = x + CGFloat(i) * childAvailable
                positionNode(child, x: cx, y: childY, available: childAvailable)
            }
        }

        positionNode(root, x: max(nodeRadius, 0), y: startY, available: width - nodeRadius * 2)
        return result
    }

    private func maxLeafCount(_ node: SpawnNode) -> Int {
        if node.children.isEmpty { return 1 }
        return node.children.reduce(0) { $0 + maxLeafCount($1) }
    }
}

// MARK: - Text align center helper

extension GraphicsContext {
    func draw(_ text: Text, in rect: CGRect, alignCenter: Bool) {
        let resolved = resolve(text)
        let measured = resolved.measure(in: CGSize(width: rect.width, height: rect.height))
        let x = rect.midX - measured.width / 2
        let y = rect.midY - measured.height / 2
        draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
    }
}
