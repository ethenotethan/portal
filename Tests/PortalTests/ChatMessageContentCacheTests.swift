import Testing
import Foundation
@testable import Portal

/// `contentWithoutAttachments` is read from every bubble body on every render,
/// and the transcript re-renders on every streamed delta. The MEDIA:-stripping
/// scan therefore runs at most once per distinct content: the cache is a
/// reference the message's copies share and `content`'s `didSet` replaces.
///
/// The regression these pin: the previous scheme primed the cache eagerly on
/// "every completion path", and the path that forgot left a bubble re-scanning
/// its whole content per render — the second long-session churn loop, caught by
/// a live sample with `stripMediaTags` under `MessageBubbleView.body`.
@Suite("ChatMessage stripped-content cache")
internal struct ChatMessageContentCacheTests {

    private static let withMedia = "Here is your report\nMEDIA:http://localhost:8642/v1/files/s1/report.pdf"
    private static let stripped = "Here is your report"

    @Test("the strip runs once per content, however many times the bubble reads it")
    internal func stripsOncePerContent() {
        let message = ChatMessage(role: .assistant, content: Self.withMedia)
        #expect(!message.hasStrippedContentCached, "nothing is computed until a bubble asks")
        PerfCounter.reset()
        for _ in 0..<50 { #expect(message.contentWithoutAttachments == Self.stripped) }
        #expect(message.hasStrippedContentCached)
        #if PERF_COUNTERS
        #expect(PerfCounter.snapshot()["chat.stripMediaTags"] == 1)
        #endif
    }

    @Test("copies share the strip; a content change invalidates it")
    internal func copiesShareAndContentChangeInvalidates() {
        var message = ChatMessage(role: .assistant, content: Self.withMedia)
        _ = message.contentWithoutAttachments
        var copy = message
        copy.showTimestamp = true // what prepareBubbleMessage does per render
        #expect(copy.hasStrippedContentCached, "a per-render copy must not re-strip")
        message.content += "\nMore prose"
        #expect(!message.hasStrippedContentCached, "new content, fresh cache")
        #expect(message.contentWithoutAttachments == Self.stripped + "\nMore prose")
        #expect(copy.contentWithoutAttachments == Self.stripped, "the copy keeps its own content and strip")
        let unchanged = message.content
        message.content = unchanged // assigning equal content keeps the cache
        #expect(message.hasStrippedContentCached)
    }

    @Test("a decoded message strips on first read, not per read — no priming needed")
    internal func decodedMessageStripsOnce() throws {
        let wire = Data("""
        {"id":"\(UUID().uuidString)","role":"assistant","content":"\(Self.withMedia.replacingOccurrences(of: "\n", with: "\\n"))"}
        """.utf8)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: wire)
        #expect(!decoded.hasStrippedContentCached)
        #expect(decoded.contentWithoutAttachments == Self.stripped)
        #expect(decoded.hasStrippedContentCached)
    }

    @Test("a round-trip through encode/decode preserves the stripped view")
    internal func roundTripPreservesStrippedContent() throws {
        let original = ChatMessage(role: .assistant, content: Self.withMedia)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(restored.contentWithoutAttachments == original.contentWithoutAttachments)
    }
}
