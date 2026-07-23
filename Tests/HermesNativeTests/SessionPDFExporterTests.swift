#if os(macOS)
import Testing
import Foundation
import PDFKit
@testable import HermesNative

@Suite("Session PDF Exporter")
struct SessionPDFExporterTests {

    @Test("Exports a session with markdown, chart, and table to valid PDF")
    @MainActor
    func exportsValidPDF() async {
        let chartJSON = """
        {"type": "bar", "title": "Revenue", "series": [
          {"name": "2025", "points": [
            {"x": "Q1", "y": 10}, {"x": "Q2", "y": 20}, {"x": "Q3", "y": 15}
          ]}
        ]}
        """
        let assistantContent = """
        # Analysis

        Here is the revenue breakdown:

        ```chart
        \(chartJSON)
        ```

        | Quarter | Revenue |
        |---------|---------|
        | Q1      | 10      |
        | Q2      | 20      |
        """
        let messages = [
            ChatMessage(role: .user, content: "Show me the revenue analysis"),
            ChatMessage(role: .assistant, content: assistantContent),
        ]

        let data = await SessionPDFExporter.export(
            messages: messages,
            title: "Revenue Session",
            assistantName: "Hermes"
        )

        let unwrapped = try! #require(data)
        let document = try! #require(PDFDocument(data: unwrapped))
        #expect(document.pageCount >= 1)
        // Body text should survive the render into the PDF text layer.
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()
        #expect(text.contains("Analysis"))
        #expect(text.contains("Show me the revenue analysis"))
    }

    @Test("Multi-series numeric-x chart (interactive in chat) exports statically")
    @MainActor
    func exportsInteractiveCapableChart() async {
        // Numeric x + several series is the configuration that gets the full
        // interactive treatment in chat (zoomable axis, legend chips,
        // crosshair). Export must render it through the static path — a
        // zoomed chart plot is a scroll view, which ImageRenderer rasterizes
        // as an empty box.
        let chartJSON = """
        {"type": "line", "title": "Latency", "xLabel": "Minute", "yLabel": "ms", "series": [
          {"name": "p50", "points": [{"x": 0, "y": 12}, {"x": 1, "y": 14}, {"x": 2, "y": 11}]},
          {"name": "p95", "points": [{"x": 0, "y": 40}, {"x": 1, "y": 55}, {"x": 2, "y": 43}]},
          {"name": "p99", "points": [{"x": 0, "y": 80}, {"x": 1, "y": 120}, {"x": 2, "y": 95}]}
        ]}
        """
        let messages = [
            ChatMessage(role: .user, content: "Plot the latency percentiles"),
            ChatMessage(role: .assistant, content: "```chart\n\(chartJSON)\n```"),
        ]

        let data = await SessionPDFExporter.export(
            messages: messages,
            title: "Latency Session",
            assistantName: "Hermes"
        )

        let unwrapped = try! #require(data)
        let document = try! #require(PDFDocument(data: unwrapped))
        #expect(document.pageCount >= 1)
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()
        // The chart card title and the legend chips render into the PDF text
        // layer; their presence proves the chart drew rather than rasterizing
        // as an empty box.
        #expect(text.contains("Latency"))
        #expect(text.contains("p95"))
    }

    @Test("Math blocks export as typeset images, not empty boxes")
    @MainActor
    func mathExportsTypeset() async {
        let messages = [
            ChatMessage(role: .user, content: "derive it"),
            ChatMessage(role: .assistant, content: """
            The quadratic formula:

            $$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$

            done.
            """),
        ]
        let data = await SessionPDFExporter.export(
            messages: messages, title: "Math", assistantName: "Hermes"
        )
        let unwrapped = try! #require(data)
        let document = try! #require(PDFDocument(data: unwrapped))
        // The typeset equation is an embedded image: the PDF must contain an
        // XObject/image stream. A monospace-text fallback would not.
        // (PDF bytes aren't UTF-8; scan for the ASCII markers directly.)
        func containsASCII(_ marker: String) -> Bool {
            unwrapped.range(of: Data(marker.utf8)) != nil
        }
        #expect(containsASCII("/Image") || containsASCII("/XObject"))
        // Surrounding prose still lands in the text layer.
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        #expect(text.contains("quadratic formula"))
    }

    @Test("Empty session returns nil instead of an empty PDF")
    @MainActor
    func emptySessionReturnsNil() async {
        let data = await SessionPDFExporter.export(messages: [], title: "Empty", assistantName: "Hermes")
        #expect(data == nil)
    }
}
#endif

@Suite("Map Export Region")
struct MapExportRegionTests {

    @Test("Model map views project to the same JSON the prerender pass keys on")
    func projectionKeyStability() {
        let modelJSON = """
        {"entities": {"spots": {"key": "name", "items": [
           {"name": "A", "lat": 13.7, "lon": 100.5}, {"name": "B", "lat": 13.72, "lon": 100.54}]}},
         "views": [{"type": "map"}]}
        """
        let spec = ModelSpec.parse(modelJSON)!
        let first = ModelProjections.mapJSON(spec: spec, view: spec.views[0])
        let second = ModelProjections.mapJSON(spec: spec, view: spec.views[0])
        // sortedKeys serialization → deterministic string; the export view's
        // dictionary lookup depends on this.
        #expect(first != nil && first == second)
        #expect(MapSpec.parse(first!)?.markers.count == 2)
    }
}
