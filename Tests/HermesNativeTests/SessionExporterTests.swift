import Testing
import Foundation
@testable import HermesNative

@Suite("Session Exporter — Markdown")
struct SessionExporterMarkdownTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func export(_ messages: [ChatMessage], metadata: SessionExporter.Metadata? = nil) -> String {
        SessionExporter.markdown(
            messages: messages,
            metadata: metadata ?? SessionExporter.Metadata(title: "Test Session", assistantName: "Hermes"),
            exportDate: fixedDate,
            timeZone: utc
        )
    }

    @Test("Empty session renders header and placeholder")
    func emptySession() {
        let md = export([])
        #expect(md.hasPrefix("# Test Session\n"))
        #expect(md.contains("_This session has no messages._"))
        #expect(md.contains("- **Messages:** 0"))
    }

    @Test("Roles render as user / assistant sections in order")
    func roleFormatting() {
        let md = export([
            ChatMessage(role: .user, content: "What is 2+2?"),
            ChatMessage(role: .assistant, content: "It is **4**."),
        ])
        let userRange = md.range(of: "## 👤 User")
        let assistantRange = md.range(of: "## 🤖 Hermes")
        #expect(userRange != nil)
        #expect(assistantRange != nil)
        if let u = userRange, let a = assistantRange {
            #expect(u.lowerBound < a.lowerBound)
        }
        #expect(md.contains("What is 2+2?"))
        #expect(md.contains("It is **4**."))
    }

    @Test("Metadata header includes session key, gateway, model, dates, usage")
    func metadataHeader() {
        let usage = SessionUsage(
            model: "claude-opus-4", inputTokens: 1200, outputTokens: 340,
            cacheReadTokens: nil, cacheWriteTokens: nil, totalTokens: 1540,
            apiCalls: 7, costUSD: 0.1234, contextUsed: nil, contextMax: nil,
            contextPercent: nil, compressions: nil
        )
        let metadata = SessionExporter.Metadata(
            title: "Research Session",
            sessionID: "20260722_101500_abc123",
            gatewayName: "Local Hermes",
            model: "claude-opus-4",
            source: "native",
            startedAt: Date(timeIntervalSince1970: 1_749_990_000),
            lastActive: Date(timeIntervalSince1970: 1_749_999_000),
            usage: usage,
            assistantName: "Hermes"
        )
        let md = export([ChatMessage(role: .user, content: "hi")], metadata: metadata)
        #expect(md.hasPrefix("# Research Session\n"))
        #expect(md.contains("- **Session:** `20260722_101500_abc123`"))
        #expect(md.contains("- **Gateway:** Local Hermes"))
        #expect(md.contains("- **Model:** `claude-opus-4`"))
        #expect(md.contains("- **Source:** native"))
        #expect(md.contains("- **Date range:** 2025-06-15"))
        #expect(md.contains("1200 in / 340 out / 1540 total tokens"))
        #expect(md.contains("7 API calls"))
        #expect(md.contains("$0.1234"))
    }

    @Test("Tool calls render as structured sections with input and result")
    func toolCallSections() {
        let tool = ToolCallRecord(
            id: "t1",
            name: "Bash",
            context: "ls -la /tmp",
            summary: "12 files listed",
            durationSeconds: 1.5,
            isComplete: true
        )
        let md = export([ChatMessage(role: .assistant, content: "Done.", toolCalls: [tool])])
        #expect(md.contains("### 🔧 tool: Bash (1.5s)"))
        #expect(md.contains("**Input:**"))
        #expect(md.contains("ls -la /tmp"))
        #expect(md.contains("**Result:**"))
        #expect(md.contains("12 files listed"))
    }

    @Test("Incomplete tool calls are marked")
    func incompleteToolCall() {
        let tool = ToolCallRecord(id: "t2", name: "WebSearch", context: "query", isComplete: false)
        let md = export([ChatMessage(role: .assistant, content: "", toolCalls: [tool])])
        #expect(md.contains("### 🔧 tool: WebSearch (incomplete)"))
    }

    @Test("Code fences inside message content are preserved verbatim")
    func codeFencePreservation() {
        let content = """
        Here is code:

        ```swift
        let x = 1
        ```

        Done.
        """
        let md = export([ChatMessage(role: .assistant, content: content)])
        #expect(md.contains("```swift\nlet x = 1\n```"))
    }

    @Test("Tool output containing triple backticks gets a longer fence")
    func fenceEscaping() {
        let payload = "outer\n```\ninner fence\n```\nend"
        let lines = SessionExporter.fenced(payload, language: "text")
        #expect(lines.first == "````text")
        #expect(lines.last == "````")
        #expect(lines.joined(separator: "\n").contains("```\ninner fence"))

        let tool = ToolCallRecord(id: "t3", name: "Read", summary: payload, isComplete: true)
        let md = export([ChatMessage(role: .assistant, content: "ok", toolCalls: [tool])])
        #expect(md.contains("````text"))
    }

    @Test("Reasoning renders as a collapsed details block")
    func reasoningBlock() {
        let md = export([ChatMessage(role: .assistant, content: "Answer", reasoning: "I should think about this.")])
        #expect(md.contains("<details>"))
        #expect(md.contains("<summary>💭 Reasoning</summary>"))
        #expect(md.contains("I should think about this."))
        #expect(md.contains("</details>"))
    }

    @Test("Thinking trace takes precedence over legacy reasoning string")
    func thinkingTracePrecedence() {
        var trace = ThinkingTrace()
        trace.append("step one\n", kind: .thinking)
        trace.append("step two", kind: .reasoning)
        trace.finish()
        let md = export([
            ChatMessage(role: .assistant, content: "Answer", reasoning: "legacy", thinkingTrace: trace)
        ])
        #expect(md.contains("step one"))
        #expect(md.contains("step two"))
        #expect(!md.contains("legacy"))
    }

    @Test("Attachments are referenced by filename, not embedded")
    func attachmentReferences() {
        var message = ChatMessage(role: .assistant, content: "See chart.")
        message.attachments = [FileAttachment(remoteURL: URL(string: "https://gw/files/s1/chart.png")!)]
        let md = export([message])
        #expect(md.contains("**Attachments (referenced, not embedded):** `chart.png`"))
        #expect(md.contains("images and file attachments are referenced by filename, not embedded"))
    }

    @Test("Interrupted turn status is noted")
    func turnStatus() {
        let md = export([ChatMessage(role: .assistant, content: "Partial answer", status: "interrupted")])
        #expect(md.contains("_Turn status: interrupted_"))
    }

    @Test("Markdown output is deterministic")
    func deterministicOutput() {
        let messages = [
            ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, role: .user, content: "hi"),
            ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, role: .assistant, content: "hello"),
        ]
        #expect(export(messages) == export(messages))
    }
}

@Suite("Session Exporter — Filenames")
struct SessionExporterFilenameTests {

    @Test("Filename slugs title and appends timestamp + extension")
    func filenameFormat() {
        let date = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15 15:06:40 UTC
        let name = SessionExporter.filename(
            title: "My Research: Phase 2!",
            fileExtension: "md",
            date: date,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(name == "my-research-phase-2-20250615-1506.md")
    }

    @Test("Empty and symbol-only titles fall back to hermes-session")
    func slugFallback() {
        #expect(SessionExporter.slugify("") == "hermes-session")
        #expect(SessionExporter.slugify("///:::") == "hermes-session")
        #expect(SessionExporter.slugify("Héllo Wörld") == "héllo-wörld")
    }

    @Test("Long titles are truncated to 60 characters")
    func slugTruncation() {
        let slug = SessionExporter.slugify(String(repeating: "a", count: 100))
        #expect(slug.count == 60)
    }
}

@Suite("Session Exporter — PDF")
struct SessionExporterPDFTests {

    @Test("PDF data is non-empty and starts with %PDF magic bytes")
    @MainActor
    func pdfMagicBytes() {
        let messages = [
            ChatMessage(role: .user, content: "Explain quicksort"),
            ChatMessage(
                role: .assistant,
                content: "Quicksort partitions:\n\n```swift\nfunc qs(_ a: [Int]) -> [Int] { a }\n```\n\nDone.",
                toolCalls: [ToolCallRecord(id: "t1", name: "Bash", context: "swift run", summary: "ok", isComplete: true)],
                reasoning: "Consider pivot selection."
            ),
        ]
        let md = SessionExporter.markdown(
            messages: messages,
            metadata: SessionExporter.Metadata(title: "Quicksort Session", assistantName: "Hermes")
        )
        let data = SessionExporter.pdf(markdown: md, title: "Quicksort Session")
        let unwrapped = try! #require(data)
        #expect(unwrapped.count > 500)
        #expect(unwrapped.prefix(4) == Data("%PDF".utf8))
    }

    @Test("Long transcripts paginate without hanging")
    @MainActor
    func pdfPagination() {
        let longBody = Array(repeating: "A paragraph of body text that fills the page. ", count: 40).joined()
        let messages = (0..<30).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: longBody)
        }
        let md = SessionExporter.markdown(
            messages: messages,
            metadata: SessionExporter.Metadata(title: "Long Session", assistantName: "Hermes")
        )
        let data = SessionExporter.pdf(markdown: md, title: "Long Session")
        let unwrapped = try! #require(data)
        #expect(unwrapped.prefix(4) == Data("%PDF".utf8))
        #expect(unwrapped.count > 5_000)
    }
}
