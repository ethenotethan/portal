import SwiftUI

/// The native system map for the `interplay` section of the contract: the
/// application hull with its pages, clusters and constructions; the boundary
/// groups and the gateway around it; edges bundled onto whatever is open. Hulls
/// start closed from the outermost shell and open on click. Beneath the canvas:
/// the system flows (closed headers that open to their steps and light them on
/// the map) and the invariants as an enumerated list.
@MainActor
internal struct ArchitectureSystemMapSectionView: View {
    @StateObject private var model: ArchitectureSystemMapModel
    private let hasMap: Bool
    @State private var openFlows: Set<String> = []
    @State private var legendOpen = false

    internal init(document: ArchitectureModelDocument) {
        let map = ArchitectureSystemMapDocument.decode(document: document)
        hasMap = map != nil
        let empty = ArchitectureSystemMapDocument(nodes: [], edges: [], pages: [], boundaryGroups: [], clusters: [], flows: [], invariants: [])
        _model = StateObject(wrappedValue: ArchitectureSystemMapModel(document: map ?? empty))
    }

    internal var body: some View {
        if hasMap {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                    HStack(alignment: .top, spacing: 0) {
                        ArchitectureSystemMapCanvas(model: model)
                            .frame(maxWidth: .infinity)
                            .frame(height: 560)
                            .clipped()
                        if model.selectedNode != nil {
                            Divider().background(Theme.border)
                            inspector
                                .frame(width: 300)
                        }
                    }
                    .background(Theme.background)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    legend
                    flowsSection
                    invariantsSection
                }
                .padding(16)
            }
        } else {
            ArchitectureSectionPlaceholder(
                icon: ArchitectureSurfaceTab.systemMap.icon,
                title: "No system map",
                detail: "This document has no interplay section, so there is nothing to draw."
            )
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search pages, owners, endpoints, resources, or engines…", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
            Button("Expand all") { model.expandAll() }
                .portalButton(prominent: false, size: .small)
            Button("Collapse all") { model.collapseAll() }
                .portalButton(prominent: false, size: .small)
            Button("Reset view") { model.resetView() }
                .portalButton(prominent: false, size: .small)
            Toggle("Colour edges by relationship", isOn: $model.coloursEdgesByRelation)
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Spacer()
            Text("\(model.document.nodes.count) constructions · \(model.document.edges.count) edges")
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let node = model.selectedNode {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(node.kind.label.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(ArchitectureSystemMapPalette.color(for: node.kind))
                        Spacer()
                        Button {
                            model.select(nodeID: nil)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                        .help("Close inspector")
                    }
                    Text(node.label)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                    inspectorFacts(node)
                    if let summary = node.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    inspectorFlows(node)
                }
                .padding(14)
            }
        }
    }

    private func inspectorFacts(_ node: ArchitectureMapNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let component = node.component { fact("component", component) }
            if let page = node.page { fact("page", page) }
            if let owner = node.ownerType { fact("owner", owner) }
            if let subKind = node.subKind { fact("sub-kind", subKind) }
            if let site = node.sourceSite { fact("source", site) }
        }
    }

    private func fact(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func inspectorFlows(_ node: ArchitectureMapNode) -> some View {
        let flows = model.flows(involving: node.id)
        if !flows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("FLOWS · \(flows.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
                ForEach(flows) { flow in
                    Button {
                        openFlows.insert(flow.id)
                        model.setActiveFlow(flow.id)
                    } label: {
                        Text(flow.title)
                            .font(.caption)
                            .foregroundStyle(model.activeFlowID == flow.id ? Theme.accent : Theme.primary)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Legend

    private var legend: some View {
        DisclosureGroup(isExpanded: $legendOpen) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(ArchitectureNodeKind.legend, id: \.rawValue) { kind in
                    HStack(spacing: 6) {
                        Circle().fill(ArchitectureSystemMapPalette.color(for: kind)).frame(width: 7, height: 7)
                        Text(kind.label).font(.caption2).foregroundStyle(Theme.secondary)
                    }
                }
                if model.coloursEdgesByRelation {
                    ForEach(ArchitectureEdgeClass.legend, id: \.rawValue) { edgeClass in
                        HStack(spacing: 6) {
                            Rectangle().fill(ArchitectureSystemMapPalette.color(for: edgeClass)).frame(width: 14, height: 2)
                            Text("\(edgeClass.rawValue) edge").font(.caption2).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("LEGEND")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: Flows

    private var flowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System flows")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text("\(model.document.flows.count) flows, each validated step by step against the map on every build. Open one to read its steps and light them above.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            ForEach(model.document.flows) { flow in
                flowRow(flow)
            }
        }
        .padding(.top, 8)
    }

    private func flowRow(_ flow: ArchitectureFlow) -> some View {
        let isOpen = Binding<Bool>(
            get: { openFlows.contains(flow.id) },
            set: { open in
                if open {
                    openFlows.insert(flow.id)
                    model.setActiveFlow(flow.id)
                } else {
                    openFlows.remove(flow.id)
                    if model.activeFlowID == flow.id { model.setActiveFlow(nil) }
                }
            }
        )
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if !flow.summary.isEmpty {
                    Text(flow.summary).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !flow.interaction.isEmpty {
                    Text("When: \(flow.interaction)").font(.caption2).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(flow.steps.enumerated()), id: \.offset) { index, step in
                    stepRow(index + 1, step)
                }
                if !flow.outcome.isEmpty {
                    Text("Outcome: \(flow.outcome)").font(.caption2).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Text(flow.title)
                    .font(.subheadline)
                    .foregroundStyle(model.activeFlowID == flow.id ? Theme.accent : Theme.primary)
                if let page = flow.page {
                    Text(page)
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if !flow.journey.isEmpty {
                    Text(flow.journey)
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
                Text("\(flow.steps.count) steps · \(flow.status.isEmpty ? "untraced" : flow.status)")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func stepRow(_ number: Int, _ step: ArchitectureFlowStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 24, alignment: .trailing)
                Text(endpointLabel(step.from))
                    .font(.system(size: 11, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
                Text("→ \(step.relation) →")
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.accent)
                Text(endpointLabel(step.to))
                    .font(.system(size: 11, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
            }
            if !step.note.isEmpty {
                Text(step.note)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func endpointLabel(_ reference: String) -> String {
        switch model.document.resolve(stepEndpoint: reference) {
        case .node(let id):
            return model.document.node(id: id)?.label ?? id
        case .page(let id):
            return model.document.pages.first { $0.id == id }?.label ?? id
        case .unknown(let raw):
            return raw
        }
    }

    // MARK: Invariants

    private var invariantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invariants")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text("What the map assumes, declared and checked on every build.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            ForEach(Array(model.document.invariants.enumerated()), id: \.offset) { index, invariant in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 28, alignment: .trailing)
                    Text(invariant.status.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(invariant.holds ? Theme.success : Theme.warning)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(invariant.id)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.primary)
                            Text("\(invariant.kind) · checked \(invariant.checked)")
                                .font(.system(size: 9, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(invariant.why)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Palette

/// One colour per construction kind and per edge class, from the theme's graph palette.
internal enum ArchitectureSystemMapPalette {
    internal static func color(for kind: ArchitectureNodeKind) -> Color {
        switch kind {
        case .hub, .seam: return Theme.agentAccent
        case .owner: return Theme.graphOther
        case .provider, .machine: return Theme.graphPatch
        case .caller: return Theme.graphTerminal
        case .client, .subscriber: return Theme.graphRead
        case .endpoint: return Theme.accent
        case .section: return Theme.graphCompaction
        case .resource, .operation: return Theme.graphReasoning
        case .store, .artifact: return Theme.graphWrite
        case .external: return Theme.warning
        case .custom: return Theme.secondary
        }
    }

    internal static func color(for edgeClass: ArchitectureEdgeClass) -> Color {
        switch edgeClass {
        case .structure: return Theme.tertiary
        case .interplay: return Theme.accent
        case .lifecycle: return Theme.graphReasoning
        case .boundary: return Theme.warning
        case .usage: return Theme.graphTerminal
        case .custom: return Theme.secondary
        }
    }
}

// MARK: - Canvas

/// The pan-and-zoom canvas: hulls, then bundled edges, then nodes, in content
/// coordinates under the model's transform. Mouse handling mirrors the cron
/// graph: a press that moves pans, a press that does not is a tap.
@MainActor
internal struct ArchitectureSystemMapCanvas: View {
    @ObservedObject internal var model: ArchitectureSystemMapModel
    @State private var pressStart: CGPoint?
    @State private var pressPan: CGSize = .zero
    @State private var panning = false
    @State private var pinchStart: CGFloat?

    internal var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas(rendersAsynchronously: false) { context, _ in
                    draw(in: &context)
                }
                .background(Theme.background)
                #if os(macOS)
                GraphMouseInterceptor(
                    onMouseDown: { point in pressStart = point; pressPan = model.panOffset; panning = false },
                    onMouseDragged: { point in dragged(to: point) },
                    onMouseUp: { _ in released() },
                    onScrollWheel: { delta in
                        model.panOffset = CGSize(width: model.panOffset.width + delta.width, height: model.panOffset.height + delta.height)
                    },
                    onMouseMoved: { _ in },
                    onMouseExited: {}
                )
                #else
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .onTapGesture { point in
                        model.handleTap(atContent: model.contentPoint(fromView: point))
                    }
                #endif
            }
            .gesture(pinchGesture(center: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)))
            .onAppear { model.fit(in: geometry.size) }
        }
    }

    private func dragged(to point: CGPoint) {
        guard let start = pressStart else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        if !panning && hypot(dx, dy) > 5 { panning = true }
        if panning {
            model.panOffset = CGSize(width: pressPan.width + dx, height: pressPan.height + dy)
        }
    }

    private func released() {
        if !panning, let start = pressStart {
            model.handleTap(atContent: model.contentPoint(fromView: start))
        }
        pressStart = nil
        panning = false
    }

    #if !os(macOS)
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if pressStart == nil { pressStart = value.startLocation; pressPan = model.panOffset; panning = true }
                model.panOffset = CGSize(width: pressPan.width + value.translation.width, height: pressPan.height + value.translation.height)
            }
            .onEnded { _ in
                pressStart = nil
                panning = false
            }
    }
    #endif

    private func pinchGesture(center: CGPoint) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = model.zoom }
                guard let start = pinchStart else { return }
                let target = start * value
                model.zoomAtPoint(factor: target / model.zoom, around: center)
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        context.translateBy(x: model.panOffset.width, y: model.panOffset.height)
        context.scaleBy(x: model.zoom, y: model.zoom)
        let layout = model.layout
        let hulls = layout.frames.filter(\.element.isHull).sorted { $0.depth < $1.depth }
        for frame in hulls {
            drawHull(frame, in: &context)
        }
        for bundle in layout.bundles {
            drawBundle(bundle, in: &context)
        }
        for frame in layout.frames where !frame.element.isHull {
            drawNode(frame, in: &context)
        }
    }

    private func drawHull(_ frame: ArchitectureMapFrame, in context: inout GraphicsContext) {
        guard let hull = model.tree.hull(frame.element.id) else { return }
        var local = context
        if model.isDimmed(frame.element) { local.opacity = 0.25 }
        let path = Path(roundedRect: frame.frame, cornerRadius: hull.kind == .application ? 12 : 8)
        let (fill, stroke, style) = hullStyle(hull.kind)
        local.fill(path, with: .color(fill))
        local.stroke(path, with: .color(stroke), style: style)
        let label = Text(hull.label)
            .font(.system(size: frame.collapsed ? 13 : 10, weight: .semibold))
            .foregroundColor(Theme.primary)
        let title = Text(hullKindTitle(hull.kind).uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .monospaced()
            .foregroundColor(Theme.tertiary)
        let inset = frame.frame.insetBy(dx: 10, dy: 6)
        if frame.collapsed {
            local.draw(local.resolve(title), in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 12))
            local.draw(local.resolve(label), in: CGRect(x: inset.minX, y: inset.minY + 13, width: inset.width, height: 18))
            let count = Text("\(model.tree.constructionCount(of: hull.id)) constructions")
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundColor(Theme.secondary)
            local.draw(local.resolve(count), in: CGRect(x: inset.minX, y: inset.minY + 32, width: inset.width, height: 12))
        } else {
            local.draw(local.resolve(label), in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14))
        }
    }

    private func hullKindTitle(_ kind: ArchitectureHullKind) -> String {
        switch kind {
        case .application: return "application"
        case .page: return "page"
        case .cluster: return "owner"
        case .boundary: return "boundary"
        case .container: return "storage"
        case .gateway: return "backend"
        case .externals: return "external"
        }
    }

    private func hullStyle(_ kind: ArchitectureHullKind) -> (Color, Color, StrokeStyle) {
        switch kind {
        case .application:
            return (Theme.accent.opacity(0.05), Theme.border, StrokeStyle(lineWidth: 1.5))
        case .page:
            return (Theme.surface.opacity(0.6), Theme.border, StrokeStyle(lineWidth: 1))
        case .cluster:
            return (Theme.background.opacity(0.4), Theme.border.opacity(0.8), StrokeStyle(lineWidth: 1, dash: [2, 4]))
        case .boundary, .externals:
            return (Theme.warning.opacity(0.05), Theme.warning.opacity(0.7), StrokeStyle(lineWidth: 1, dash: [6, 4]))
        case .container:
            return (Theme.graphWrite.opacity(0.05), Theme.graphWrite.opacity(0.6), StrokeStyle(lineWidth: 1))
        case .gateway:
            return (Theme.warning.opacity(0.06), Theme.warning.opacity(0.8), StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    private func drawNode(_ frame: ArchitectureMapFrame, in context: inout GraphicsContext) {
        guard let node = model.document.node(id: frame.element.id) else { return }
        var local = context
        if model.isDimmed(frame.element) { local.opacity = 0.2 }
        let selected = model.selectedNodeID == node.id
        let box = Path(roundedRect: frame.frame, cornerRadius: 5)
        let tint = ArchitectureSystemMapPalette.color(for: node.kind)
        local.fill(box, with: .color(Theme.surface))
        local.stroke(box, with: .color(selected ? Theme.accent : Theme.border), lineWidth: selected ? 2 : 1)
        let bar = CGRect(x: frame.frame.minX, y: frame.frame.minY + 6, width: 3, height: frame.frame.height - 12)
        local.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(tint))
        let label = Text(node.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.primary)
        local.draw(local.resolve(label), in: frame.frame.insetBy(dx: 10, dy: 4).offsetBy(dx: 2, dy: 0))
    }

    private func drawBundle(_ bundle: ArchitectureMapBundle, in context: inout GraphicsContext) {
        guard let source = model.layout.frame(of: bundle.source), let target = model.layout.frame(of: bundle.target) else { return }
        let anchors = ArchitectureSystemMapLayout.anchors(from: source, to: target)
        let highlighted = model.isHighlighted(bundle)
        let dimmed = model.isDimmed(bundle.source) || model.isDimmed(bundle.target)
        var local = context
        if dimmed && !highlighted { local.opacity = 0.15 }
        let color: Color
        if highlighted {
            color = Theme.accent
        } else if model.coloursEdgesByRelation, let edgeClass = bundle.uniformClass {
            color = ArchitectureSystemMapPalette.color(for: edgeClass)
        } else {
            color = Theme.border
        }
        let width = highlighted ? 2 : min(1 + CGFloat(bundle.count - 1) * 0.35, 3)
        var path = Path()
        path.move(to: anchors.start)
        let dx = anchors.end.x - anchors.start.x
        let control1 = CGPoint(x: anchors.start.x + dx * 0.4, y: anchors.start.y)
        let control2 = CGPoint(x: anchors.end.x - dx * 0.4, y: anchors.end.y)
        path.addCurve(to: anchors.end, control1: control1, control2: control2)
        local.stroke(path, with: .color(highlighted ? color : color.opacity(0.75)), lineWidth: width)
        drawArrowhead(at: anchors.end, from: control2, color: color, in: &local)
        // A bundle names its count; a lit single edge names its relation.
        let caption = bundle.count > 1 ? "\(bundle.count)" : (highlighted ? bundle.relations.joined(separator: ", ") : "")
        if !caption.isEmpty {
            let midpoint = CGPoint(x: (anchors.start.x + anchors.end.x) / 2, y: (anchors.start.y + anchors.end.y) / 2)
            let label = Text(caption)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundColor(highlighted ? Theme.accent : Theme.secondary)
            local.draw(local.resolve(label), at: midpoint)
        }
    }

    private func drawArrowhead(at tip: CGPoint, from tail: CGPoint, color: Color, in context: inout GraphicsContext) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let size: CGFloat = 6
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - size * cos(angle - .pi / 6), y: tip.y - size * sin(angle - .pi / 6)))
        head.addLine(to: CGPoint(x: tip.x - size * cos(angle + .pi / 6), y: tip.y - size * sin(angle + .pi / 6)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}
