import Testing
import CoreGraphics
@testable import Portal

@Suite("Network graph canvas sizing")
internal struct NetworkGraphCanvasSizingTests {
    private let fixture = """
    {
      "directed": true,
      "nodes": [
        {"id":"node-1"}, {"id":"node-2"}, {"id":"node-3"},
        {"id":"node-4"}, {"id":"node-5"}, {"id":"node-6"},
        {"id":"node-7"}, {"id":"node-8"}, {"id":"node-9"}
      ],
      "edges": [
        {"from":"node-1","to":"node-2"},
        {"from":"node-2","to":"node-3"},
        {"from":"node-3","to":"node-4"},
        {"from":"node-4","to":"node-5"},
        {"from":"node-5","to":"node-6"},
        {"from":"node-6","to":"node-7"},
        {"from":"node-7","to":"node-8"},
        {"from":"node-8","to":"node-9"}
      ]
    }
    """

    @Test("graph groups keep their first-seen order without duplicates")
    internal func groupsPreserveFirstAppearance() throws {
        let spec = try #require(NetworkGraphSpec.parse("""
        {
          "nodes": [
            {"id":"api","group":"services"},
            {"id":"worker","group":"compute"},
            {"id":"database","group":"services"},
            {"id":"ungrouped"}
          ]
        }
        """))

        #expect(spec.groups == ["services", "compute"])
    }

    @Test("a single node is centered in the requested layout box")
    internal func singleNodeIsCentered() throws {
        let spec = try #require(NetworkGraphSpec.parse(#"{"nodes":[{"id":"solo"}]}"#))
        let result = NetworkGraphLayout.layout(spec, width: 360, fitHeight: 140)
        let node = try #require(result.placed.first)

        #expect(result.size == CGSize(width: 360, height: 140))
        #expect(node.position == CGPoint(x: 180, y: 70))
        #expect(result.positions["solo"] == node.position)
    }

    @Test("canvas reports the height of the layout at its actual width")
    internal func heightUsesActualWidth() throws {
        let spec = try #require(NetworkGraphSpec.parse(fixture))
        let narrowWidth: CGFloat = 320
        let wideWidth: CGFloat = 600

        let narrowHeight = NetworkGraphCanvasSizing.height(for: spec, width: narrowWidth)
        let wideHeight = NetworkGraphCanvasSizing.height(for: spec, width: wideWidth)

        #expect(narrowHeight == NetworkGraphLayout.layout(spec, width: narrowWidth).size.height
            + NetworkGraphCanvasSizing.bottomLabelPadding)
        #expect(wideHeight == NetworkGraphLayout.layout(spec, width: wideWidth).size.height
            + NetworkGraphCanvasSizing.bottomLabelPadding)
        #expect(narrowHeight != wideHeight)
    }

    @Test("a fit height bounds the layout box and every node lands inside it")
    internal func fitHeightBoundsLayout() throws {
        let spec = try #require(NetworkGraphSpec.parse(fixture))
        let fitHeight: CGFloat = 200
        let result = NetworkGraphLayout.layout(spec, width: 600, fitHeight: fitHeight)

        #expect(result.size.height == fitHeight)
        for placed in result.placed {
            #expect(placed.position.y >= 0)
            #expect(placed.position.y <= fitHeight)
            #expect(placed.position.x >= 0)
            #expect(placed.position.x <= 600)
        }
    }

    @Test("fit-height layout is cached separately from intrinsic layout")
    internal func fitHeightMemoKeyIsDistinct() throws {
        let spec = try #require(NetworkGraphSpec.parse(fixture))
        let intrinsic = NetworkGraphLayout.layout(spec, width: 600)
        let fitted = NetworkGraphLayout.layout(spec, width: 600, fitHeight: 150)

        // The intrinsic layout of this 9-node chain is far taller than 150,
        // so a shared memo entry would return the wrong geometry.
        #expect(intrinsic.size.height != fitted.size.height)
        #expect(fitted.size.height == 150)
    }

    @Test("invalid transient widths fall back to the stable nominal width")
    internal func invalidWidthFallback() throws {
        let spec = try #require(NetworkGraphSpec.parse(fixture))
        let expected = NetworkGraphLayout.layout(
            spec,
            width: NetworkGraphCanvasSizing.nominalWidth
        ).size.height + NetworkGraphCanvasSizing.bottomLabelPadding

        #expect(NetworkGraphCanvasSizing.height(for: spec, width: 0) == expected)
        #expect(NetworkGraphCanvasSizing.height(for: spec, width: .infinity) == expected)
    }

    @Test("model projection preserves direction and runtime metadata")
    internal func modelProjectionPreservesRuntimeMetadata() throws {
        let model = try #require(ModelSpec.parse("""
        {"entities": {
           "jobs": {"key": "id", "items": [
             {"id": "sync", "kind": "cron", "type": "product-sync"}]},
           "resources": {"key": "id", "items": [
             {"id": "github", "kind": "source", "type": "github"}]}
         },
         "relations": [
           {"from": "jobs/sync", "to": "resources/github", "type": "reads",
            "class": "dataflow", "note": "PR state"}
         ],
         "views": [{"type": "graph", "directed": true}]}
        """))
        let view = try #require(model.views.first)
        let graphJSON = try #require(ModelProjections.graphJSON(spec: model, view: view))
        let graph = try #require(NetworkGraphSpec.parse(graphJSON))

        #expect(view.directed)
        #expect(graph.directed)
        #expect(graph.nodes.first { $0.id == "jobs/sync" }?.kind == "cron")
        #expect(graph.nodes.first { $0.id == "jobs/sync" }?.type == "product-sync")
        #expect(graph.nodes.first { $0.id == "resources/github" }?.kind == "source")
        #expect(graph.nodes.first { $0.id == "resources/github" }?.type == "github")
        let edge = try #require(graph.edges.first)
        #expect(edge.type == "reads")
        #expect(edge.edgeClass == "dataflow")
        #expect(edge.label == "PR state")
    }

    @Test("typed entities opt legacy model graphs into relation semantics")
    internal func typedEntitiesEnableRelationSemantics() throws {
        let model = try #require(ModelSpec.parse("""
        {"entities": {
           "services": {"key": "id", "items": [
             {"id": "worker", "kind": "service"},
             {"id": "index", "kind": "artifact"}]}
         },
         "relations": [
           {"from": "services/worker", "to": "services/index", "type": "writes",
            "note": "search index"}
         ],
         "views": [{"type": "graph"}]}
        """))
        let view = try #require(model.views.first)
        let graphJSON = try #require(ModelProjections.graphJSON(spec: model, view: view))
        let graph = try #require(NetworkGraphSpec.parse(graphJSON))
        let edge = try #require(graph.edges.first)

        #expect(!view.hasExplicitDirection)
        #expect(!graph.directed)
        #expect(edge.type == "writes")
        #expect(edge.label == "search index")
    }

    @Test("typed graph derives runtime-style node and edge legend semantics")
    internal func typedLegendSemantics() throws {
        let spec = try #require(NetworkGraphSpec.parse("""
        {"nodes": [
           {"id": "worker", "kind": "service", "type": "agent"},
           {"id": "file", "kind": "artifact", "type": "file"},
           {"id": "slack", "kind": "sink", "type": "slack"}
         ],
         "edges": [
           {"from": "worker", "to": "file", "type": "writes", "class": "dataflow"},
           {"from": "worker", "to": "slack", "type": "delivers", "class": "delivery"},
           {"from": "worker", "to": "file", "type": "owns", "class": "authority"},
           {"from": "file", "to": "worker", "type": "contains", "class": "containment"}
         ]}
        """))

        #expect(spec.nodeLegend.map { "\($0.kind)/\($0.type)" } == [
            "service/agent", "artifact/file", "sink/slack",
        ])
        #expect(spec.edgeLegend.map { "\($0.type)/\($0.edgeClass ?? "")" } == [
            "writes/dataflow", "delivers/delivery", "owns/authority", "contains/containment",
        ])
        #expect(NetworkGraphVisualSemantics.appearance(for: spec.edges[0]) == .dataflow)
        #expect(NetworkGraphVisualSemantics.appearance(for: spec.edges[1]) == .delivery)
        #expect(NetworkGraphVisualSemantics.appearance(for: spec.edges[2]) == .authority)
        #expect(NetworkGraphVisualSemantics.appearance(for: spec.edges[3]) == .containment)
        #expect(NetworkGraphVisualSemantics.appearance(for: spec.edges[3]).isDashed)
        #expect(!NetworkGraphVisualSemantics.appearance(for: spec.edges[3]).showsArrow)
    }

    @Test("legacy type-only edges retain their visual semantics")
    internal func typeOnlyEdgeSemantics() throws {
        let spec = try #require(NetworkGraphSpec.parse("""
        {"nodes": [{"id": "a"}, {"id": "b"}],
         "edges": [
           {"from": "a", "to": "b", "type": "reads"},
           {"from": "a", "to": "b", "type": "delivery"},
           {"from": "a", "to": "b", "type": "hosts"},
           {"from": "a", "to": "b", "type": "owns"},
           {"from": "a", "to": "b", "type": "controls"},
           {"from": "a", "to": "b", "type": "custom"}
         ]}
        """))

        #expect(spec.edges.map(NetworkGraphVisualSemantics.appearance) == [
            .dataflow, .delivery, .containment, .authority, .control, .generic,
        ])
    }

    @Test("Interactive graph adapter preserves typed directed semantics")
    internal func interactiveGraphSemantics() throws {
        let spec = try #require(NetworkGraphSpec.parse("""
        {"directed": true,
         "nodes": [
           {"id": "worker", "kind": "service", "type": "agent"},
           {"id": "file", "kind": "artifact", "type": "report"}
         ],
         "edges": [
           {"from": "worker", "to": "file", "label": "daily report",
            "type": "writes", "class": "dataflow"}
         ]}
        """))
        let semantics = NetworkGraphInteractiveSemantics(spec: spec)

        #expect(semantics.directed)
        #expect(semantics.node(id: "worker")?.kind == "service")
        #expect(semantics.node(id: "worker")?.type == "agent")
        let edge = try #require(semantics.edge(at: 0))
        #expect(edge.type == "writes")
        #expect(edge.edgeClass == "dataflow")
        #expect(semantics.appearance(at: 0) == .dataflow)
        #expect(semantics.nodeLegend.count == 2)
        #expect(semantics.edgeLegend.count == 1)
    }
}
