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

    @Test("Empty session returns nil instead of an empty PDF")
    @MainActor
    func emptySessionReturnsNil() async {
        let data = await SessionPDFExporter.export(messages: [], title: "Empty", assistantName: "Hermes")
        #expect(data == nil)
    }
}
#endif
