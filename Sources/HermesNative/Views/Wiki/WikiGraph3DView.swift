import SwiftUI
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct WikiGraph3DView: View {
    @ObservedObject var viewModel: WikiGraphViewModel

    var body: some View {
        _WikiGraph3DRepresentable(viewModel: viewModel)
            .background(Theme.background)
    }
}

// MARK: - Platform Representable

#if os(macOS)
private struct _WikiGraph3DRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: WikiGraphViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> SCNView {
        makeSceneView(context: context)
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        context.coordinator.sync(from: viewModel, in: scnView)
    }
}
#else
private struct _WikiGraph3DRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: WikiGraphViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeUIView(context: Context) -> SCNView {
        makeSceneView(context: context)
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.sync(from: viewModel, in: scnView)
    }
}
#endif

// MARK: - Scene Setup

private func makeSceneView(context: Any) -> SCNView {
    let scnView = SCNView()
    scnView.scene = SCNScene()
    #if os(macOS)
    scnView.backgroundColor = .clear
    #else
    scnView.backgroundColor = UIColor.clear
    #endif
    scnView.allowsCameraControl = true
    scnView.antialiasingMode = .multisampling4X
    scnView.rendersContinuously = false

    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.zFar = 10000
    cameraNode.camera?.fieldOfView = 45
    cameraNode.position = SCNVector3(0, 80, 480)
    cameraNode.look(at: SCNVector3(0, 0, 0))
    scnView.scene?.rootNode.addChildNode(cameraNode)

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    #if os(macOS)
    ambient.light?.color = NSColor(white: 0.45, alpha: 1.0)
    #else
    ambient.light?.color = UIColor(white: 0.45, alpha: 1.0)
    #endif
    scnView.scene?.rootNode.addChildNode(ambient)

    let directional = SCNNode()
    directional.light = SCNLight()
    directional.light?.type = .directional
    #if os(macOS)
    directional.light?.color = NSColor(white: 0.7, alpha: 1.0)
    #else
    directional.light?.color = UIColor(white: 0.7, alpha: 1.0)
    #endif
    directional.position = SCNVector3(1, 2, 1)
    scnView.scene?.rootNode.addChildNode(directional)

    let graphRoot = SCNNode()
    graphRoot.name = "graphRoot"
    scnView.scene?.rootNode.addChildNode(graphRoot)

    #if os(macOS)
    let click = NSClickGestureRecognizer()
    scnView.addGestureRecognizer(click)
    #else
    let tap = UITapGestureRecognizer()
    scnView.addGestureRecognizer(tap)
    #endif

    return scnView
}

// MARK: - Coordinator

private final class Coordinator: NSObject {
    private let viewModel: WikiGraphViewModel
    private var nodeMap: [String: SCNNode] = [:]
    private var labelMap: [String: SCNNode] = [:]
    private var indexByID: [String: Int] = [:]
    private var edgeNode: SCNNode?
    private var labelContainer: SCNNode?
    private var lastTopologyKey: String = ""
    private var labelCullDistance: Float = 800
    private var cameraMinDistance: Float = 100
    private var cameraMaxDistance: Float = 4000
    private var edgesNeedFinalRebuild = true
    private var hasFittedCamera = false

    init(viewModel: WikiGraphViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func sync(from vm: WikiGraphViewModel, in scnView: SCNView) {
        clampCamera(scnView)

        let topologyKey = vm.simNodes.map { $0.id }.sorted().joined(separator: ",")
        if topologyKey != lastTopologyKey || nodeMap.isEmpty {
            rebuildScene(from: vm, in: scnView)
            lastTopologyKey = topologyKey
            return
        }

        updatePositions(from: vm, in: scnView)

        let currentIndex = vm.selectedNodeIndex
        if currentIndex != lastHighlightedIndex {
            updateSelectionHighlight(from: vm)
            lastHighlightedIndex = currentIndex
        }
    }

    private var lastHighlightedIndex: Int?

    @MainActor
    private func rebuildScene(from vm: WikiGraphViewModel, in scnView: SCNView) {
        guard let graphRoot = scnView.scene?.rootNode.childNode(withName: "graphRoot", recursively: false),
              !vm.simNodes.isEmpty else { return }

        graphRoot.childNodes.forEach { $0.removeFromParentNode() }
        nodeMap.removeAll()
        labelMap.removeAll()
        indexByID = Dictionary(uniqueKeysWithValues: vm.simNodes.enumerated().map { ($1.id, $0) })
        edgesNeedFinalRebuild = true
        hasFittedCamera = false

        labelContainer = SCNNode()
        labelContainer?.name = "labels"
        graphRoot.addChildNode(labelContainer!)

        for (idx, simNode) in vm.simNodes.enumerated() {
            let r = CGFloat(4 + vm.nodeRadius(at: idx) * 0.8)
            let sphere = SCNSphere(radius: r)
            let nodeColor = vm.color(for: simNode.type)
            let nsColor = PlatformColor(nodeColor)
            sphere.firstMaterial?.diffuse.contents = nsColor
            sphere.firstMaterial?.emission.contents = nsColor.withAlphaComponent(0.25)
            sphere.firstMaterial?.lightingModel = .constant

            let scnNode = SCNNode(geometry: sphere)
            scnNode.name = simNode.id
            scnNode.position = SCNVector3(simNode.position3D)
            graphRoot.addChildNode(scnNode)
            nodeMap[simNode.id] = scnNode

            let labelText = SCNText(string: simNode.label, extrusionDepth: 0)
            #if os(macOS)
            labelText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            labelText.firstMaterial?.diffuse.contents = NSColor(white: 0.9, alpha: 1.0)
            #else
            labelText.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            labelText.firstMaterial?.diffuse.contents = UIColor(white: 0.9, alpha: 1.0)
            #endif
            labelText.flatness = 0.4

            let labelNode = SCNNode(geometry: labelText)
            labelNode.name = "label:\(simNode.id)"
            labelNode.position = SCNVector3(simNode.position3D.x, simNode.position3D.y + 7, simNode.position3D.z)
            // Scale label slightly with node importance.
            let degree = vm.degrees.indices.contains(idx) ? vm.degrees[idx] : 0
            let labelScale = 1.0 + min(Float(degree) * 0.06, 0.8)
            labelNode.scale = SCNVector3(labelScale, labelScale, labelScale)
            labelNode.constraints = [SCNBillboardConstraint()]
            labelContainer?.addChildNode(labelNode)
            labelMap[simNode.id] = labelNode
        }

        buildEdgeGeometry(from: vm, graphRoot: graphRoot)
        fitCamera(to: vm, in: scnView)

        #if os(macOS)
        if let click = scnView.gestureRecognizers.first as? NSClickGestureRecognizer {
            click.target = self
            click.action = #selector(handleClick(_:))
        }
        #else
        if let tap = scnView.gestureRecognizers?.first as? UITapGestureRecognizer {
            tap.addTarget(self, action: #selector(handleTap(_:)))
        }
        #endif
    }

    @MainActor
    private func buildEdgeGeometry(from vm: WikiGraphViewModel, graphRoot: SCNNode) {
        edgeNode?.removeFromParentNode()

        guard !vm.simLinks.isEmpty else { return }

        let count = vm.simLinks.count
        var vertices = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: count * 2)
        var indices = [Int32]()
        for (i, (si, ti)) in vm.simLinks.enumerated() {
            vertices[i * 2] = SCNVector3(vm.simNodes[si].position3D)
            vertices[i * 2 + 1] = SCNVector3(vm.simNodes[ti].position3D)
            indices.append(Int32(i * 2))
            indices.append(Int32(i * 2 + 1))
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .line,
            primitiveCount: count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        let geom = SCNGeometry(sources: [vertexSource], elements: [element])
        #if os(macOS)
        geom.firstMaterial?.diffuse.contents = NSColor(red: 0.49, green: 0.49, blue: 1.0, alpha: 0.32)
        #else
        geom.firstMaterial?.diffuse.contents = UIColor(red: 0.49, green: 0.49, blue: 1.0, alpha: 0.32)
        #endif
        geom.firstMaterial?.lightingModel = .constant

        let node = SCNNode(geometry: geom)
        graphRoot.addChildNode(node)
        edgeNode = node
    }

    @MainActor
    private func updatePositions(from vm: WikiGraphViewModel, in scnView: SCNView) {
        let selectedIndex = vm.selectedNodeIndex
        let neighborIndices: Set<Int> = selectedIndex.map { vm.neighbors(of: $0) } ?? []
        let hasSelection = selectedIndex != nil
        let cameraPos: SIMD3<Float>? = scnView.pointOfView?.presentation.simdWorldPosition

        for (idx, simNode) in vm.simNodes.enumerated() {
            guard let scnNode = nodeMap[simNode.id] else { continue }
            scnNode.position = SCNVector3(simNode.position3D)

            if let labelNode = labelMap[simNode.id] {
                labelNode.position = SCNVector3(simNode.position3D.x, simNode.position3D.y + 7, simNode.position3D.z)
                let isAnchorOrNeighbor = idx == selectedIndex || neighborIndices.contains(idx)
                let degree = vm.degrees.indices.contains(idx) ? vm.degrees[idx] : 0
                // No selection: only label well-connected nodes to reduce clutter.
                let isImportant = hasSelection ? isAnchorOrNeighbor : degree >= 2
                let isClose = cameraPos.map { simd_distance(simNode.position3D, $0) < labelCullDistance } ?? true
                labelNode.isHidden = !(isAnchorOrNeighbor || (isImportant && isClose))
            }
        }

        // 0.003 matches the tick guard in WikiGraphView so the final rebuild
        // happens on the last real tick.
        let simHot = vm.simAlpha > 0.003 || vm.simNodes.contains(where: { $0.isDragging })
        if simHot {
            // Rebuild edge lines every sync while hot so they track moving spheres.
            if let root = edgeNode?.parent { rebuildEdgeGeometry(from: vm, graphRoot: root) }
            edgesNeedFinalRebuild = true
        } else if edgesNeedFinalRebuild {
            if let root = edgeNode?.parent { rebuildEdgeGeometry(from: vm, graphRoot: root) }
            edgesNeedFinalRebuild = false
            if !hasFittedCamera { fitCamera(to: vm, in: scnView); hasFittedCamera = true }
        }
    }

    /// Positions the camera so the whole graph fits in the 45-degree FOV with margin.
    @MainActor
    private func fitCamera(to vm: WikiGraphViewModel, in scnView: SCNView) {
        guard !vm.simNodes.isEmpty,
              let cameraNode = scnView.pointOfView ?? scnView.scene?.rootNode.childNodes.first(where: { $0.camera != nil }) else { return }
        var centroid = SIMD3<Float>.zero
        for n in vm.simNodes { centroid += n.position3D }
        centroid /= Float(vm.simNodes.count)
        var radius: Float = 0
        for n in vm.simNodes { radius = max(radius, simd_distance(n.position3D, centroid)) }
        radius = max(radius, 100)

        let fov = Float((cameraNode.camera?.fieldOfView ?? 45) * .pi / 180)
        let distance = radius / tan(fov / 2) * 1.25
        cameraMinDistance = max(radius * 0.15, 50)
        cameraMaxDistance = max(distance * 4, 1000)
        cameraNode.position = SCNVector3(centroid.x, centroid.y + radius * 0.2, centroid.z + distance)
        cameraNode.look(at: SCNVector3(centroid))
        labelCullDistance = distance * 1.5
    }

    @MainActor
    private func rebuildEdgeGeometry(from vm: WikiGraphViewModel, graphRoot: SCNNode) {
        edgeNode?.removeFromParentNode()
        buildEdgeGeometry(from: vm, graphRoot: graphRoot)
    }

    @MainActor
    private func updateSelectionHighlight(from vm: WikiGraphViewModel) {
        let selectedIndex: Int? = {
            guard let idx = vm.selectedNodeIndex, vm.simNodes.indices.contains(idx) else { return nil }
            return idx
        }()
        let selectedID = selectedIndex.map { vm.simNodes[$0].id }
        let neighborIndices: Set<Int> = selectedIndex.map { vm.neighbors(of: $0) } ?? []

        let filtering = vm.isFiltering
        let filteredSet = vm.filteredNodeIndices

        for (id, scnNode) in nodeMap {
            guard let geom = scnNode.geometry else { continue }
            let idx = indexByID[id]
            let isSelected = id == selectedID
            let isNeighbor = idx.map { neighborIndices.contains($0) } ?? false
            let hasSelection = selectedID != nil && !neighborIndices.isEmpty

            let matchesFilter = !filtering || (idx != nil && filteredSet.contains(idx!))
            let filterDim: CGFloat = matchesFilter ? 1.0 : 0.12

            if isSelected {
                #if os(macOS)
                geom.firstMaterial?.emission.contents = NSColor(white: 0.4, alpha: 1.0)
                #else
                geom.firstMaterial?.emission.contents = UIColor(white: 0.4, alpha: 1.0)
                #endif
                let pulse = SCNAction.sequence([
                    .scale(to: 1.25, duration: 0.15),
                    .scale(to: 1.0, duration: 0.15),
                ])
                scnNode.runAction(.repeatForever(pulse))
            } else if hasSelection && !isNeighbor {
                #if os(macOS)
                geom.firstMaterial?.diffuse.contents = NSColor(white: 0.25 * filterDim, alpha: 1.0)
                #else
                geom.firstMaterial?.diffuse.contents = UIColor(white: 0.25 * filterDim, alpha: 1.0)
                #endif
                scnNode.removeAllActions()
            } else {
                let nodeType = idx.map { vm.simNodes[$0].type } ?? ""
                let nodeColor = vm.color(for: nodeType)
                geom.firstMaterial?.diffuse.contents = PlatformColor(nodeColor).withAlphaComponent(filterDim)
                scnNode.removeAllActions()
            }
        }
    }

    #if os(macOS)
    @MainActor
    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let scnView = recognizer.view as? SCNView else { return }
        let pt = recognizer.location(in: scnView)
        selectNode(at: pt, scnView: scnView)
    }
    #else
    @MainActor
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let scnView = recognizer.view as? SCNView else { return }
        let pt = recognizer.location(in: scnView)
        selectNode(at: pt, scnView: scnView)
    }
    #endif

    @MainActor
    private func clampCamera(_ scnView: SCNView) {
        guard let cameraNode = scnView.pointOfView ?? scnView.scene?.rootNode.childNodes.first(where: { $0.camera != nil }),
              let camera = cameraNode.camera else { return }
        let dist = simd_length(cameraNode.simdPosition)
        if dist < cameraMinDistance || dist > cameraMaxDistance {
            let clamped = simd_clamp(dist, cameraMinDistance, cameraMaxDistance)
            let dir = cameraNode.simdPosition / dist
            cameraNode.simdPosition = dir * clamped
        }
    }

    @MainActor
    private func selectNode(at point: CGPoint, scnView: SCNView) {
        let hits = scnView.hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
        ])
        for hit in hits {
            guard let name = hit.node.name, !name.hasPrefix("label:") else { continue }
            guard let idx = indexByID[name], viewModel.simNodes.indices.contains(idx) else { continue }
            if viewModel.selectedNodeIndex == idx {
                if let page = viewModel.graph.pages.first(where: { $0.id == name }) {
                    viewModel.selectedPage = page
                    viewModel.showPageDetail = true
                }
            } else {
                viewModel.selectedNodeIndex = idx
            }
            #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            #endif
            return
        }
        viewModel.deselectNode()
    }
}

// PlatformColor already defined in PlatformCompat.swift
