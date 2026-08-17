import Testing
import Foundation
@testable import Portal

/// Why MarkdownContentView renders blocks by POSITION and must keep doing so.
///
/// `MarkdownBlock.id` is content-derived, and repetitive documents therefore
/// produce duplicate ids — SwiftUI's ForEach renders undefined under
/// duplicates (wrong identity or dropped views). Caught live as
/// `ForEach<Array<MarkdownBlock>, String, …> Invalid Configuration` in the
/// run log while Learning lesson pages rendered wrong: structured lesson
/// markdown repeats itself (`---` separators, recurring callout paragraphs)
/// far more than chat prose does, which is why Learning surfaced it first.
@Suite("Markdown block identity")
internal struct MarkdownBlockIdentityTests {

    @Test("content-derived ids collide on repetitive documents — the hazard, pinned")
    internal func contentIDsCollide() {
        // Two rules and a repeated paragraph: perfectly legal markdown that
        // any lesson/summary layout produces.
        let blocks = MarkdownParser.parse("""
        Key takeaway: identity must be unique.

        ---

        Some middle content.

        ---

        Key takeaway: identity must be unique.
        """)
        let ids = blocks.map(\.id)
        #expect(
            Set(ids).count < ids.count,
            """
            If this ever fails, MarkdownBlock.id became collision-free and the
            positional ForEach in MarkdownContentView could return to
            Identifiable — until then, ForEach(blocks) is undefined behavior
            on repetitive documents.
            """
        )
    }

    @Test("the block ForEach uses positional identity")
    internal func forEachIsPositional() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Comment bodies stripped before the absence check: the fix's own
        // comment names the wrong pattern right above the right one (the
        // CanvasRelayoutGuardTests lesson, relearned).
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Portal/Views/MarkdownContentView.swift"),
            encoding: .utf8
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let marker = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<marker.lowerBound])
        }
        .joined(separator: "\n")
        #expect(
            source.contains("ForEach(Array(blocks.enumerated()), id: \\.offset)"),
            "block rendering must key on position — content-derived ids collide (see contentIDsCollide)"
        )
        #expect(
            !source.contains("ForEach(blocks)"),
            "ForEach(blocks) uses MarkdownBlock's colliding Identifiable id"
        )
    }

    @Test("a repetitive lesson parses into renderable entries for every block")
    internal func repetitiveLessonKeepsAllBlocks() {
        // The parse itself must not dedup — position is the identity, so all
        // three paragraphs and both rules exist as separate entries.
        let blocks = MarkdownParser.parse("""
        Same line.

        ---

        Same line.

        ---

        Same line.
        """)
        let paragraphs = blocks.filter { if case .paragraph = $0 { return true }; return false }
        let rules = blocks.filter { if case .horizontalRule = $0 { return true }; return false }
        #expect(paragraphs.count == 3)
        #expect(rules.count == 2)
    }
}
