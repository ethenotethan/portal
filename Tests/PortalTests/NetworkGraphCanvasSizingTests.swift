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
}
