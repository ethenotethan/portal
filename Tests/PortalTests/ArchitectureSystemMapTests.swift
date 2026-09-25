import Testing
import Foundation
@testable import Portal

// MARK: - Fixture

/// A small map with every hull kind: two pages (one with a two-node cluster and
/// a lone store), a platform-storage boundary holding a container external with
/// an artifact and a plain keychain external, a gateway serving two endpoints,
/// one free external, two flows (one leaving from a page pseudo-node) and two
/// invariants.
private let fixtureJSON = """
{
  "nodes": [
    {"id": "hub:ChatViewModel", "kind": "hub", "label": "ChatViewModel", "page": "chat", "cluster": "c-chat",
     "component": "chat-state", "history_key": "hub:ChatViewModel", "path": "Sources/Portal/ViewModels/ChatViewModel.swift", "line": 38,
     "semantic": {"summary": "Owns the conversation."}, "flows": ["send-message"]},
    {"id": "owner:GatewayClient", "kind": "owner", "label": "GatewayClient", "page": "shared", "cluster": "c-gw",
     "component": "hermes-services", "history_key": "owner:hermes-services:GatewayClient", "owner_type": null, "path": "Sources/Portal/Services/GatewayClient.swift", "line": 30},
    {"id": "section:call", "kind": "section", "label": "call", "cluster": "c-gw", "owner_type": "GatewayClient",
     "component": "hermes-services", "history_key": "section:hermes-services:GatewayClient:call", "sub_kind": "critical_section"},
    {"id": "store:ActivityStore", "kind": "store", "label": "ActivityStore", "page": "activity", "cluster": "c-store",
     "component": "domain-models", "history_key": "store:domain-models:ActivityStore"},
    {"id": "endpoint:abc", "kind": "endpoint", "label": "session", "owner_type": "GatewayClient", "cluster": "c-ep", "history_key": "endpoint:jsonrpc:session"},
    {"id": "endpoint:def", "kind": "endpoint", "label": "cron", "owner_type": "GatewayClient", "cluster": "c-ep", "history_key": "endpoint:jsonrpc:cron"},
    {"id": "external:harness-gateway", "kind": "external", "label": "Harness gateway", "owner_type": "External systems", "history_key": "external:harness-gateway"},
    {"id": "external:user-defaults", "kind": "external", "label": "UserDefaults", "owner_type": "External systems", "history_key": "external:user-defaults"},
    {"id": "external:keychain", "kind": "external", "label": "Keychain", "owner_type": "External systems", "history_key": "external:keychain"},
    {"id": "external:weather", "kind": "external", "label": "Weather API", "owner_type": "External systems", "history_key": "external:weather"},
    {"id": "artifact:portal.items", "kind": "artifact", "label": "portal.items", "owner_type": "External systems", "history_key": "artifact:user-defaults:portal.items"},
    {"id": "novel:thing", "kind": "hologram", "label": "Novel", "history_key": "novel:thing"}
  ],
  "edges": [
    {"source": "hub:ChatViewModel", "target": "owner:GatewayClient", "relation": "calls", "class": "usage"},
    {"source": "owner:GatewayClient", "target": "section:call", "relation": "operates", "class": "lifecycle"},
    {"source": "owner:GatewayClient", "target": "endpoint:abc", "relation": "dispatches", "class": "structure"},
    {"source": "owner:GatewayClient", "target": "endpoint:def", "relation": "dispatches", "class": "structure"},
    {"source": "endpoint:abc", "target": "external:harness-gateway", "relation": "served-by", "class": "boundary"},
    {"source": "endpoint:def", "target": "external:harness-gateway", "relation": "served-by", "class": "boundary"},
    {"source": "store:ActivityStore", "target": "artifact:portal.items", "relation": "persists-to", "class": "boundary"},
    {"source": "artifact:portal.items", "target": "external:user-defaults", "relation": "stored-in", "class": "boundary"},
    {"source": "hub:ChatViewModel", "target": "external:weather", "relation": "reaches", "class": "boundary"},
    {"source": "hub:ChatViewModel", "target": "store:ActivityStore", "relation": "uses", "class": "usage"},
    {"source": "hub:ChatViewModel", "target": "novel:thing", "relation": "greets", "class": "mystery"}
  ],
  "pages": [
    {"id": "chat", "label": "Main chat view", "roots": ["ChatView"], "components": ["chat-state"], "type_count": 10},
    {"id": "activity", "label": "Activity", "roots": ["ActivityView"], "components": [], "type_count": 3},
    {"id": "empty", "label": "Nothing here", "roots": [], "components": [], "type_count": 0}
  ],
  "boundary_groups": [
    {"id": "platform-storage", "label": "Platform storage", "description": "Where the app keeps state.",
     "categories": ["storage"], "members": ["external:user-defaults", "external:keychain"]}
  ],
  "clusters": [
    {"id": "c-chat", "component": "chat-state", "owner_type": "ChatViewModel", "node_ids": ["hub:ChatViewModel"]},
    {"id": "c-gw", "component": "hermes-services", "owner_type": "GatewayClient", "node_ids": ["owner:GatewayClient", "section:call"]},
    {"id": "c-store", "component": "domain-models", "owner_type": "Data stores", "node_ids": ["store:ActivityStore"]},
    {"id": "c-ep", "component": "hermes-services", "owner_type": "GatewayClient · endpoints", "node_ids": ["endpoint:abc", "endpoint:def"]}
  ],
  "flows": [
    {"id": "send-message", "title": "Send a message", "summary": "A turn leaves the chat.", "page": "chat", "journey": "chat",
     "interaction": "user submits", "outcome": "The gateway answers.", "status": "traceable", "authority": "synthesized",
     "steps": [
       {"from": "page:chat", "to": "hub:ChatViewModel", "relation": "triggers", "note": "Send button"},
       {"from": "hub:ChatViewModel", "to": "owner:hermes-services:GatewayClient", "relation": "calls", "note": "call()"},
       {"from": "owner:hermes-services:GatewayClient", "to": "endpoint:jsonrpc:session", "relation": "dispatches", "note": ""}
     ]},
    {"id": "ghost", "title": "Ghost flow", "steps": [{"from": "nowhere", "to": "hub:ChatViewModel", "relation": "haunts"}]}
  ],
  "invariants": [
    {"id": "single-transport", "kind": "single_transport", "status": "holds", "why": "One socket.", "checked": 1},
    {"id": "pool-guarded", "kind": "pool_guarded_by_lock", "status": "violated", "why": "Lock first.", "checked": 4}
  ]
}
"""

private func decodeFixture() throws -> ArchitectureSystemMapDocument {
    let value = try JSONDecoder().decode(AnyCodable.self, from: Data(fixtureJSON.utf8))
    return ArchitectureSystemMapDocument.decode(try #require(value.dictionaryValue))
}

private func realMap() throws -> ArchitectureSystemMapDocument {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("architecture/model/model.json"))
    let model = try JSONDecoder().decode(AnyCodable.self, from: data)
    let interplay = try #require(model.dictionaryValue?["interplay"]?.dictionaryValue)
    return ArchitectureSystemMapDocument.decode(interplay)
}

private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    a.intersects(b) && a.intersection(b).width > 0.5 && a.intersection(b).height > 0.5
}

// MARK: - Decoding

@Suite("Architecture system map — typed interplay section")
internal struct ArchitectureSystemMapDocumentTests {
    @Test("decodes nodes, edges, pages, groups, clusters, flows and invariants tolerantly")
    internal func decodesFixture() throws {
        let map = try decodeFixture()
        #expect(map.nodes.count == 12)
        #expect(map.edges.count == 11)
        #expect(map.pages.map(\.id) == ["chat", "activity", "empty"])
        #expect(map.boundaryGroups.first?.members == ["external:user-defaults", "external:keychain"])
        #expect(map.clusters.count == 4)
        #expect(map.flows.count == 2)
        #expect(map.invariants.map(\.holds) == [true, false])
        let hub = try #require(map.node(id: "hub:ChatViewModel"))
        #expect(hub.kind == .hub)
        #expect(hub.summary == "Owns the conversation.")
        #expect(hub.sourceSite == "Sources/Portal/ViewModels/ChatViewModel.swift:38")
        #expect(hub.flowIDs == ["send-message"])
        let novel = try #require(map.node(id: "novel:thing"))
        #expect(novel.kind == .custom("hologram"))
        #expect(novel.kind.label == "hologram")
        #expect(novel.sourceSite == nil)
        #expect(map.edges.last?.edgeClass == .custom("mystery"))
        #expect(map.edges.first?.edgeClass == .usage)
        #expect(ArchitectureNodeKind(rawValue: "store").rawValue == "store")
        #expect(ArchitectureEdgeClass(rawValue: "lifecycle").rawValue == "lifecycle")
        #expect(ArchitectureNodeKind.legend.count == 15)
        #expect(ArchitectureEdgeClass.legend.count == 5)
    }

    @Test("every known kind and edge class round-trips through its raw value and names itself")
    internal func kindsRoundTrip() {
        for kind in ArchitectureNodeKind.legend {
            #expect(ArchitectureNodeKind(rawValue: kind.rawValue) == kind)
            #expect(!kind.label.isEmpty)
            if case .custom = kind { Issue.record("legend lists a custom kind") }
        }
        for edgeClass in ArchitectureEdgeClass.legend {
            #expect(ArchitectureEdgeClass(rawValue: edgeClass.rawValue) == edgeClass)
        }
        #expect(ArchitectureNodeKind(rawValue: "widget") == .custom("widget"))
        #expect(ArchitectureEdgeClass(rawValue: "odd").rawValue == "odd")
    }

    @Test("resolves flow endpoints by history key, then id, then page pseudo-node")
    internal func resolvesEndpoints() throws {
        let map = try decodeFixture()
        #expect(map.resolve(stepEndpoint: "owner:hermes-services:GatewayClient") == .node("owner:GatewayClient"))
        #expect(map.resolve(stepEndpoint: "hub:ChatViewModel") == .node("hub:ChatViewModel"))
        #expect(map.resolve(stepEndpoint: "page:chat") == .page("chat"))
        #expect(map.resolve(stepEndpoint: "page:missing") == .unknown("page:missing"))
        #expect(map.resolve(stepEndpoint: "nowhere") == .unknown("nowhere"))
        #expect(map.node(historyKey: "endpoint:jsonrpc:session")?.id == "endpoint:abc")
        #expect(map.node(id: "absent") == nil)
        // Flows involving a node: named on the node, or walked by a step.
        #expect(map.flows(involving: "hub:ChatViewModel").map(\.id) == ["send-message", "ghost"])
        #expect(map.flows(involving: "endpoint:abc").map(\.id) == ["send-message"])
        #expect(map.flows(involving: "external:keychain").isEmpty)
        #expect(map.flows(involving: "nope").isEmpty)
    }

    @Test("decodes the real compiled model with every kind known")
    internal func decodesRealModel() throws {
        let map = try realMap()
        #expect(map.nodes.count > 100)
        #expect(map.edges.count > map.nodes.count)
        #expect(map.pages.count == 12)
        #expect(map.flows.count > 30)
        #expect(!map.invariants.isEmpty)
        for node in map.nodes {
            if case .custom = node.kind { Issue.record("unknown kind \(node.kind.rawValue) on \(node.id)") }
        }
        for edge in map.edges {
            if case .custom = edge.edgeClass { Issue.record("unknown class on \(edge.source) → \(edge.target)") }
        }
        // Every step of every flow lands on the map.
        for flow in map.flows {
            for step in flow.steps {
                for reference in [step.from, step.to] {
                    if case .unknown = map.resolve(stepEndpoint: reference) { Issue.record("\(flow.id): \(reference) is not on the map") }
                }
            }
        }
        let withoutInterplay = try emptyDocument()
        #expect(ArchitectureSystemMapDocument.decode(document: withoutInterplay) == nil)
    }

    private func emptyDocument() throws -> ArchitectureModelDocument {
        let json = """
        {"service": {"id": "arch:x", "label": "X", "description": "", "source": "local", "model_path": "m.json", "check_configured": false},
         "revision": "r", "source": "local", "model": {"schema_version": "1.0.0", "components": []}}
        """
        return try ArchitectureModelDocument.decodeGatewayValue(try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8)))
    }
}

// MARK: - Hull tree

@Suite("Architecture system map — hull tree")
internal struct ArchitectureHullTreeTests {
    @Test("the application hull is named after the model's title; pages and clusters keep their own labels")
    internal func applicationLabelFollowsTheTitle() throws {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(fixtureJSON.utf8))
        let section = try #require(value.dictionaryValue)
        let camera = ArchitectureHullTree.build(from: ArchitectureSystemMapDocument.decode(section, title: "Home Awareness Camera Service"))
        #expect(camera.hull("hull:application")?.label == "Home Awareness Camera Service")
        #expect(camera.hull("hull:page:chat")?.label == "Main chat view")
        #expect(camera.hull("hull:page:shared")?.label == "Shared core")
        #expect(camera.hull("hull:cluster:c-gw")?.label == "GatewayClient")
        #expect(camera.hull("hull:boundary:platform-storage")?.label == "Platform storage")
        #expect(camera.hull("hull:gateway:external:harness-gateway")?.label == "Harness gateway")
        // A section decoded on its own has no title: the hull says "Application", never "Portal".
        let bare = ArchitectureHullTree.build(from: ArchitectureSystemMapDocument.decode(section))
        #expect(bare.hull("hull:application")?.label == "Application")
        #expect(ArchitectureSystemMapDocument.decode(section, title: "   ").applicationLabel == "Application")
        // No hull label anywhere is hard-coded to Portal.
        let labels = camera.hulls.values.map(\.label)
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("portal") })
    }

    @Test("decoding from a whole document takes the model's title for the application hull")
    internal func titleFromDocument() throws {
        let envelope = """
        {"service": {"id": "arch:cam", "label": "Camera", "description": "", "source": "local", "model_path": "m.json", "check_configured": false},
         "revision": "r1", "source": "local", "summary": {"title": "Camera Service Architecture"},
         "model": {"schema_version": "1.0.0", "title": "Camera Service Architecture", "interplay": \(fixtureJSON)}}
        """
        let document = try ArchitectureModelDocument.decodeGatewayValue(try JSONDecoder().decode(AnyCodable.self, from: Data(envelope.utf8)))
        let map = try #require(ArchitectureSystemMapDocument.decode(document: document))
        #expect(map.title == "Camera Service Architecture")
        #expect(ArchitectureHullTree.build(from: map).hull("hull:application")?.label == "Camera Service Architecture")
    }

    @Test("places every construction in exactly one hull path and orders the roots")
    internal func buildsTree() throws {
        let map = try decodeFixture()
        let tree = ArchitectureHullTree.build(from: map)
        #expect(tree.rootIDs == ["hull:boundary:platform-storage", "hull:externals", "hull:application", "hull:gateway:external:harness-gateway"])
        // Pages follow the document order; the shared core comes last; the empty page is not drawn.
        #expect(tree.hull("hull:application")?.childHullIDs == ["hull:page:chat", "hull:page:activity", "hull:page:shared"])
        // A cluster of two becomes a hull; a cluster of one draws its node directly in the page.
        #expect(tree.hull("hull:page:shared")?.childHullIDs == ["hull:cluster:c-gw"])
        #expect(tree.hull("hull:cluster:c-gw")?.label == "GatewayClient")
        #expect(tree.hull("hull:cluster:c-gw")?.nodeIDs == ["owner:GatewayClient", "section:call"])
        #expect(tree.hull("hull:page:chat")?.nodeIDs == ["hub:ChatViewModel"])
        #expect(tree.hull("hull:page:activity")?.nodeIDs == ["store:ActivityStore"])
        // The unknown-kind node lands in the shared core like any page-less construction.
        #expect(tree.hull("hull:page:shared")?.nodeIDs == ["novel:thing"])
        // Storage: the boundary holds the container (which stands for UserDefaults) and the plain keychain node.
        #expect(tree.hull("hull:boundary:platform-storage")?.childHullIDs == ["hull:container:external:user-defaults"])
        #expect(tree.hull("hull:boundary:platform-storage")?.nodeIDs == ["external:keychain"])
        #expect(tree.hull("hull:container:external:user-defaults")?.representsNodeID == "external:user-defaults")
        #expect(tree.hull("hull:container:external:user-defaults")?.nodeIDs == ["artifact:portal.items"])
        #expect(tree.representedBy["external:user-defaults"] == "hull:container:external:user-defaults")
        // The gateway stands for the backend and holds its endpoints; a free external has its own hull.
        #expect(tree.hull("hull:gateway:external:harness-gateway")?.nodeIDs == ["endpoint:abc", "endpoint:def"])
        #expect(tree.representedBy["external:harness-gateway"] == "hull:gateway:external:harness-gateway")
        #expect(tree.hull("hull:externals")?.nodeIDs == ["external:weather"])
        // Paths and counts.
        #expect(tree.path(toNode: "section:call") == ["hull:application", "hull:page:shared", "hull:cluster:c-gw"])
        #expect(tree.path(toNode: "external:user-defaults") == ["hull:boundary:platform-storage", "hull:container:external:user-defaults"])
        #expect(tree.path(toNode: "missing").isEmpty)
        #expect(tree.constructionCount(of: "hull:application") == 5)
        #expect(tree.constructionCount(of: "hull:boundary:platform-storage") == 3)
        #expect(tree.constructionCount(of: "hull:gateway:external:harness-gateway") == 3)
        #expect(tree.descendantNodeIDs(of: "nope").isEmpty)
        let placed = map.nodes.filter { tree.hullOfNode[$0.id] != nil || tree.representedBy[$0.id] != nil }
        #expect(placed.count == map.nodes.count, "every construction is in a hull or stands for one")
    }

    @Test("the real model's tree covers every node once and is deterministic")
    internal func realTree() throws {
        let map = try realMap()
        let tree = ArchitectureHullTree.build(from: map)
        #expect(tree == ArchitectureHullTree.build(from: map))
        for node in map.nodes {
            #expect(!tree.path(toNode: node.id).isEmpty, "\(node.id) has no hull path")
        }
        var seen: [String: Int] = [:]
        for hull in tree.hulls.values {
            for id in hull.nodeIDs { seen[id, default: 0] += 1 }
            if let represented = hull.representsNodeID { seen[represented, default: 0] += 1 }
        }
        #expect(seen.values.allSatisfy { $0 == 1 }, "a construction sits in exactly one hull")
        #expect(seen.count == map.nodes.count)
        #expect(tree.rootIDs.contains("hull:application"))
        #expect(tree.rootIDs.contains("hull:gateway:external:harness-gateway"))
        #expect(tree.rootIDs.filter { tree.hull($0)?.kind == .boundary }.count == map.boundaryGroups.count)
    }
}

// MARK: - Layout

@Suite("Architecture system map — layout")
internal struct ArchitectureSystemMapLayoutTests {
    @Test("collapsed roots draw as fixed boxes and every edge bundles onto them")
    internal func collapsedLayout() throws {
        let map = try decodeFixture()
        let tree = ArchitectureHullTree.build(from: map)
        let layout = ArchitectureSystemMapLayout.layout(document: map, tree: tree, expanded: [])
        #expect(layout.frames.count == 4)
        #expect(layout.frames.allSatisfy { $0.collapsed })
        #expect(layout.frames.allSatisfy { $0.frame.size == ArchitectureSystemMapLayout.collapsedHullSize })
        for node in map.nodes {
            let representative = try #require(layout.representative(ofNode: node.id))
            #expect(representative.isHull)
            #expect(tree.rootIDs.contains(representative.id))
        }
        #expect(layout.representative(ofNode: "missing") == nil)
        // application → gateway (2 dispatches), application → storage (persists-to), application → externals (reaches);
        // stored-in and served-by are containment, never arrows.
        let ids = layout.bundles.map(\.id)
        #expect(ids == [
            "hull:application→hull:boundary:platform-storage",
            "hull:application→hull:externals",
            "hull:application→hull:gateway:external:harness-gateway",
        ])
        let gateway = try #require(layout.bundles.first { $0.target.id == "hull:gateway:external:harness-gateway" })
        #expect(gateway.count == 2)
        #expect(gateway.relations == ["dispatches"])
        #expect(gateway.uniformClass == .structure)
        // Columns: boundaries left, application right of them, gateway beneath the application.
        let boundary = try #require(layout.frame(of: .hull("hull:boundary:platform-storage")))
        let application = try #require(layout.frame(of: .hull("hull:application")))
        let gatewayFrame = try #require(layout.frame(of: .hull("hull:gateway:external:harness-gateway")))
        #expect(boundary.maxX < application.minX)
        #expect(gatewayFrame.minY > application.maxY)
        #expect(gatewayFrame.minX == application.minX)
        #expect(layout.size.width > application.maxX && layout.size.height > gatewayFrame.maxY)
        #expect(layout.hitTest(CGPoint(x: application.midX, y: application.midY)) == .hull("hull:application"))
        #expect(layout.hitTest(CGPoint(x: -5, y: -5)) == nil)
        #expect(layout == ArchitectureSystemMapLayout.layout(document: map, tree: tree, expanded: []))
    }

    @Test("opening hulls reveals their contents without overlaps and re-routes the edges")
    internal func expandedLayout() throws {
        let map = try decodeFixture()
        let tree = ArchitectureHullTree.build(from: map)
        let everything = Set(tree.hulls.keys)
        let layout = ArchitectureSystemMapLayout.layout(document: map, tree: tree, expanded: everything)
        #expect(layout.frames.filter(\.element.isHull).count == tree.hulls.count)
        #expect(layout.frames.filter { !$0.element.isHull }.count == map.nodes.count - tree.representedBy.count)
        // Siblings never overlap; children stay inside their parent.
        for hull in tree.hulls.values {
            let parent = try #require(layout.frame(of: .hull(hull.id)))
            let children = hull.childHullIDs.map(ArchitectureMapElement.hull) + hull.nodeIDs.map(ArchitectureMapElement.node)
            let frames = children.compactMap(layout.frame(of:))
            #expect(frames.count == children.count)
            for frame in frames { #expect(parent.contains(frame), "\(hull.id) does not contain a child") }
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) { #expect(!overlaps(a, b), "siblings overlap in \(hull.id)") }
            }
        }
        // Roots never overlap either.
        let roots = tree.rootIDs.compactMap { layout.frame(of: .hull($0)) }
        for (i, a) in roots.enumerated() {
            for b in roots.dropFirst(i + 1) { #expect(!overlaps(a, b)) }
        }
        // Representatives are now the nodes, except the externals a container or gateway stands for.
        #expect(layout.representative(ofNode: "hub:ChatViewModel") == .node("hub:ChatViewModel"))
        #expect(layout.representative(ofNode: "external:user-defaults") == .hull("hull:container:external:user-defaults"))
        #expect(layout.representative(ofNode: "external:harness-gateway") == .hull("hull:gateway:external:harness-gateway"))
        // hub→owner, owner→section, owner→endpoint×2, store→artifact, hub→weather, hub→store, hub→novel = 8 bundles
        #expect(layout.bundles.count == 8)
        #expect(layout.bundles.allSatisfy { $0.count == 1 })
        #expect(layout.bundles.contains { $0.source == .node("store:ActivityStore") && $0.target == .node("artifact:portal.items") })
        #expect(!layout.bundles.contains { $0.source == .node("artifact:portal.items") }, "stored-in is containment")
        #expect(!layout.bundles.contains { $0.source == .node("endpoint:abc") }, "served-by is containment")
        // Hit testing prefers the innermost element.
        let node = try #require(layout.frame(of: .node("section:call")))
        #expect(layout.hitTest(CGPoint(x: node.midX, y: node.midY)) == .node("section:call"))
        let cluster = try #require(layout.frame(of: .hull("hull:cluster:c-gw")))
        #expect(layout.hitTest(CGPoint(x: cluster.minX + 2, y: cluster.minY + 2)) == .hull("hull:cluster:c-gw"))
        #expect(layout.expanded.contains("hull:application"))
        // Partial expansion: only the application open → pages are the representatives of their nodes.
        let partial = ArchitectureSystemMapLayout.layout(document: map, tree: tree, expanded: ["hull:application"])
        #expect(partial.representative(ofNode: "section:call") == .hull("hull:page:shared"))
        #expect(partial.representative(ofNode: "hub:ChatViewModel") == .hull("hull:page:chat"))
        #expect(partial.bundles.contains { $0.id == "hull:page:chat→hull:page:shared" })
        #expect(partial.bundles.contains { $0.id == "hull:page:shared→hull:gateway:external:harness-gateway" && $0.count == 2 })
    }

    @Test("anchors sit on the borders along the centre line and packing is deterministic")
    internal func geometry() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 300, y: 0, width: 100, height: 50)
        let anchors = ArchitectureSystemMapLayout.anchors(from: a, to: b)
        #expect(anchors.start == CGPoint(x: 100, y: 25))
        #expect(anchors.end == CGPoint(x: 300, y: 25))
        let below = CGRect(x: 0, y: 200, width: 100, height: 50)
        let vertical = ArchitectureSystemMapLayout.anchors(from: a, to: below)
        #expect(vertical.start == CGPoint(x: 50, y: 50))
        #expect(vertical.end == CGPoint(x: 50, y: 200))
        let same = ArchitectureSystemMapLayout.anchors(from: a, to: a)
        #expect(same.start == CGPoint(x: 50, y: 25))
        let packed = ArchitectureSystemMapLayout.pack(Array(repeating: CGSize(width: 100, height: 30), count: 4))
        #expect(packed.origins.count == 4)
        #expect(packed.origins.first == .zero)
        #expect(packed.size.width >= 100 && packed.size.height >= 30)
        #expect(packed.origins == ArchitectureSystemMapLayout.pack(Array(repeating: CGSize(width: 100, height: 30), count: 4)).origins)
        #expect(ArchitectureSystemMapLayout.pack([]).origins.isEmpty)
        #expect(ArchitectureSystemMapLayout.pack([]).size == .zero)
        let rows = ArchitectureSystemMapLayout.pack(Array(repeating: CGSize(width: 148, height: 34), count: 9))
        #expect(Set(rows.origins.map(\.y)).count > 1, "nine nodes wrap onto more than one row")
    }

    @Test("the real model lays out fully expanded without overlaps, quickly")
    internal func realLayout() throws {
        let map = try realMap()
        let tree = ArchitectureHullTree.build(from: map)
        let started = Date()
        let layout = ArchitectureSystemMapLayout.layout(document: map, tree: tree, expanded: Set(tree.hulls.keys))
        #expect(Date().timeIntervalSince(started) < 2)
        for hull in tree.hulls.values {
            let children = hull.childHullIDs.map(ArchitectureMapElement.hull) + hull.nodeIDs.map(ArchitectureMapElement.node)
            let frames = children.compactMap(layout.frame(of:))
            #expect(frames.count == children.count, "\(hull.id) is missing a child frame")
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) { #expect(!overlaps(a, b), "siblings overlap in \(hull.id)") }
            }
        }
        for node in map.nodes where tree.representedBy[node.id] == nil {
            #expect(layout.frame(of: .node(node.id)) != nil, "\(node.id) has no frame")
        }
        #expect(!layout.bundles.isEmpty)
        #expect(layout.bundles.flatMap(\.edgeIndices).count <= map.edges.count)
    }
}

// MARK: - Queries and the model

@Suite("Architecture system map — queries")
internal struct ArchitectureSystemMapQueriesTests {
    @Test("edges touching a node, a flow's edges, its nodes, and search matching")
    internal func queries() throws {
        let map = try decodeFixture()
        #expect(ArchitectureSystemMapQueries.edgeIndices(touching: "store:ActivityStore", in: map) == [6, 9])
        #expect(ArchitectureSystemMapQueries.edgeIndices(touching: "nope", in: map).isEmpty)
        let flow = try #require(map.flows.first)
        // page:chat → hub has no edge; hub → owner (calls) is edge 0; owner → session endpoint (dispatches) is edge 2.
        #expect(ArchitectureSystemMapQueries.edgeIndices(for: flow, in: map) == [0, 2])
        #expect(ArchitectureSystemMapQueries.nodeIDs(visitedBy: flow, in: map) == ["hub:ChatViewModel", "owner:GatewayClient", "endpoint:abc"])
        let ghost = try #require(map.flows.last)
        #expect(ArchitectureSystemMapQueries.edgeIndices(for: ghost, in: map).isEmpty)
        #expect(ArchitectureSystemMapQueries.nodeIDs(visitedBy: ghost, in: map) == ["hub:ChatViewModel"])
        #expect(ArchitectureSystemMapQueries.matchingNodeIDs("   ", in: map) == nil)
        let gateway: Set<String> = ["owner:GatewayClient", "section:call", "endpoint:abc", "endpoint:def", "external:harness-gateway"]
        #expect(ArchitectureSystemMapQueries.matchingNodeIDs("gateway", in: map) == gateway)
        #expect(ArchitectureSystemMapQueries.matchingNodeIDs("Keychain", in: map) == ["external:keychain"])
        #expect(ArchitectureSystemMapQueries.matchingNodeIDs("chatviewmodel.swift", in: map) == ["hub:ChatViewModel"])
        #expect(ArchitectureSystemMapQueries.matchingNodeIDs("zzz", in: map)?.isEmpty == true)
    }
}

@MainActor
@Suite("Architecture system map — model")
internal struct ArchitectureSystemMapModelTests {
    @Test("starts closed, opens and closes hulls, and closing a hull closes what it holds")
    internal func hullActions() throws {
        let model = ArchitectureSystemMapModel(document: try decodeFixture())
        #expect(model.expandedHulls.isEmpty)
        #expect(model.layout.frames.count == 4)
        model.toggleHull("hull:application")
        #expect(model.expandedHulls == ["hull:application"])
        #expect(model.layout.frames.contains { $0.element == .hull("hull:page:chat") })
        model.toggleHull("hull:page:shared")
        model.toggleHull("hull:cluster:c-gw")
        #expect(model.expandedHulls.count == 3)
        model.toggleHull("hull:application")
        #expect(model.expandedHulls.isEmpty, "closing the shell closes everything inside")
        model.toggleHull("not-a-hull")
        #expect(model.expandedHulls.isEmpty)
        model.expandAll()
        #expect(model.expandedHulls == Set(model.tree.hulls.keys))
        model.collapseAll()
        #expect(model.expandedHulls.isEmpty)
    }

    @Test("taps select nodes, toggle hulls, and clear on empty space")
    internal func taps() throws {
        let model = ArchitectureSystemMapModel(document: try decodeFixture())
        let application = try #require(model.layout.frame(of: .hull("hull:application")))
        model.handleTap(atContent: CGPoint(x: application.midX, y: application.midY))
        #expect(model.expandedHulls.contains("hull:application"))
        model.toggleHull("hull:page:chat")
        let hub = try #require(model.layout.frame(of: .node("hub:ChatViewModel")))
        model.handleTap(atContent: CGPoint(x: hub.midX, y: hub.midY))
        #expect(model.selectedNodeID == "hub:ChatViewModel")
        #expect(model.selectedNode?.label == "ChatViewModel")
        #expect(model.highlightedEdgeIndices == [0, 8, 9, 10])
        #expect(model.flows(involving: "hub:ChatViewModel").count == 2)
        model.handleTap(atContent: CGPoint(x: hub.midX, y: hub.midY))
        #expect(model.selectedNodeID == nil, "tapping the selection again clears it")
        model.select(nodeID: "hub:ChatViewModel")
        model.handleTap(atContent: CGPoint(x: -100, y: -100))
        #expect(model.selectedNodeID == nil)
        #expect(model.highlightedEdgeIndices.isEmpty)
    }

    @Test("an active flow opens the hulls it walks and lights its edges; search dims what it misses")
    internal func flowsAndSearch() throws {
        let model = ArchitectureSystemMapModel(document: try decodeFixture())
        model.setActiveFlow("send-message")
        #expect(model.activeFlow?.id == "send-message")
        let walked: Set<String> = ["hull:application", "hull:page:chat", "hull:page:shared", "hull:cluster:c-gw", "hull:gateway:external:harness-gateway"]
        #expect(model.expandedHulls.isSuperset(of: walked))
        #expect(model.highlightedEdgeIndices == [0, 2])
        let lit = model.layout.bundles.filter(model.isHighlighted)
        #expect(lit.count == 2)
        model.setActiveFlow("no-such-flow")
        #expect(model.activeFlowID == nil)
        model.setActiveFlow(nil)
        #expect(model.highlightedEdgeIndices.isEmpty)
        #expect(model.dimmedNodeIDs == nil)
        #expect(!model.isDimmed(.node("external:keychain")))
        model.searchText = "keychain"
        #expect(model.dimmedNodeIDs?.contains("hub:ChatViewModel") == true)
        #expect(model.isDimmed(.node("hub:ChatViewModel")))
        #expect(!model.isDimmed(.node("external:keychain")))
        #expect(!model.isDimmed(.hull("hull:boundary:platform-storage")), "a hull with a match stays lit")
        #expect(model.isDimmed(.hull("hull:application")))
        #expect(!model.isDimmed(.hull("no-such-hull")), "an empty hull is never dimmed")
        model.resetView()
        #expect(model.searchText.isEmpty)
        #expect(model.expandedHulls.isEmpty)
        #expect(model.activeFlowID == nil)
        #expect(model.zoom == 1)
        #expect(model.panOffset == .zero)
    }

    @Test("zoom keeps the point under the cursor fixed, clamps, and fit centres the map")
    internal func geometry() throws {
        let model = ArchitectureSystemMapModel(document: try decodeFixture())
        model.panOffset = CGSize(width: 10, height: 20)
        model.zoom = 2
        #expect(model.contentPoint(fromView: CGPoint(x: 210, y: 220)) == CGPoint(x: 100, y: 100))
        let anchor = CGPoint(x: 210, y: 220)
        model.zoomAtPoint(factor: 0.5, around: anchor)
        #expect(model.zoom == 1)
        #expect(model.contentPoint(fromView: anchor) == CGPoint(x: 100, y: 100))
        model.zoomAtPoint(factor: 100, around: anchor)
        #expect(model.zoom == ArchitectureSystemMapModel.maximumZoom)
        model.zoomAtPoint(factor: 0.0001, around: anchor)
        #expect(model.zoom == ArchitectureSystemMapModel.minimumZoom)
        let before = model.panOffset
        model.zoomAtPoint(factor: 0.5, around: anchor)
        #expect(model.panOffset == before, "already at the floor: nothing moves")
        model.fit(in: CGSize(width: 2000, height: 1000))
        #expect(model.zoom == 1, "a map smaller than the viewport is not enlarged")
        #expect(model.panOffset.width == (2000 - model.layout.size.width) / 2)
        model.fit(in: CGSize(width: 100, height: 100))
        #expect(model.zoom == ArchitectureSystemMapModel.minimumZoom)
        model.fit(in: .zero)
        #expect(model.zoom == ArchitectureSystemMapModel.minimumZoom, "an empty viewport changes nothing")
    }
}
