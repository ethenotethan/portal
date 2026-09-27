import Foundation
import Testing

/// Structural guards for feed cards whose child renderers can otherwise ignore
/// an inherited line limit or expand to the full width-derived media height.
@Suite("Feed card compact sizing")
internal struct FeedCardCompactSizingTests {
    private static let viewsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources/Portal/Views")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: viewsRoot.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("GitHub release notes use a compact text renderer until expanded")
    internal func githubReleaseNotesAreCompactByDefault() throws {
        let source = try Self.source("GitHubReleaseCard.swift")

        #expect(source.contains("if isExpanded {\n                        MarkdownContentView(text: releaseBody)"))
        #expect(source.contains("} else {\n                        // MarkdownContentView"))
        #expect(source.contains("MarkdownText(text: releaseBody)"))
        #expect(source.contains(".lineLimit(5)"))
        #expect(
            !source.contains("MarkdownContentView(text: releaseBody)\n                        .lineLimit"),
            "A line limit inherited by MarkdownContentView caps every block independently, so a long release still dominates the feed."
        )
    }

    @Test("YouTube thumbnails have a fixed compact height before playback")
    internal func youtubePreviewIsCompactBeforePlayback() throws {
        let source = try Self.source("YouTubeVideoCard.swift")

        #expect(source.contains("private static let collapsedPreviewHeight: CGFloat = 280"))
        #expect(source.contains(".frame(height: Self.collapsedPreviewHeight)"))
        #expect(
            source.contains("if isPlaying, let videoID"),
            "Starting playback remains the explicit expansion path to the full 16:9 player."
        )
    }
}
