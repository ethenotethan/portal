import Testing
import Foundation
@testable import Portal

/// `contentWithoutAttachments` is read from `MessageBubbleView.body` (twice per
/// assistant bubble) and re-read on every render — and the transcript
/// re-renders many times a second while a reply is read aloud or the pane
/// auto-scrolls. So the MEDIA:-stripping scan must not run per render: the
/// result is memoized in `_contentWithoutAttachments`, which every path that
/// finalizes a message has to prime.
///
/// The regression these pin: the cache is deliberately absent from
/// `CodingKeys`, so a decoded (restored/resumed) transcript arrived with it
/// nil, and every bubble re-scanned its whole content on every body pass —
/// enough, on a long restored session under TTS, to spin the main thread.
@Suite("ChatMessage stripped-content cache")
internal struct ChatMessageContentCacheTests {

    private static let withMedia = "Here is your report\nMEDIA:http://localhost:8642/v1/files/s1/report.pdf"
    private static let stripped = "Here is your report"

    @Test("priming fills the cache with the stripped content")
    internal func primePopulatesCache() {
        var message = ChatMessage(role: .assistant, content: Self.withMedia)
        // Fresh (still-streaming-shaped) message: cache empty, getter computes.
        #expect(message._contentWithoutAttachments == nil)
        message.primeStrippedContentCache()
        #expect(message._contentWithoutAttachments == Self.stripped)
        #expect(message.contentWithoutAttachments == Self.stripped)
    }

    @Test("decoding a persisted message primes the cache — restored history renders cheaply")
    internal func decodePrimesCache() throws {
        // A persisted transcript row carries `content` but not the derived cache.
        let wire = Data("""
        {"id":"\(UUID().uuidString)","role":"assistant","content":"\(Self.withMedia.replacingOccurrences(of: "\n", with: "\\n"))"}
        """.utf8)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: wire)
        // The whole point: the cache is present straight out of decode, so the
        // bubble never falls back to the per-render stripMediaTags scan.
        #expect(decoded._contentWithoutAttachments == Self.stripped)
        #expect(decoded.contentWithoutAttachments == Self.stripped)
    }

    @Test("a round-trip through encode/decode preserves the stripped view")
    internal func roundTripPreservesStrippedContent() throws {
        var original = ChatMessage(role: .assistant, content: Self.withMedia)
        original.primeStrippedContentCache()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(restored.contentWithoutAttachments == original.contentWithoutAttachments)
    }
}
