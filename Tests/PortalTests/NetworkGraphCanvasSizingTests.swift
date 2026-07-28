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
