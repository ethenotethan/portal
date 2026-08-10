import Foundation
import Testing
@testable import Portal

@Suite("MEDIA: attachment parsing & host resolution")
internal struct MediaParserTests {

    // MARK: - Host resolution on remote URLs (the delivered-attachment bug)

    @Test("A loopback attachment URL is rewritten via the resolver")
    internal func remoteURLResolvedHost() throws {
        // Agents emit MEDIA:http://localhost:8642/... which is unreachable
        // off-device; the resolver swaps the host for the reachable gateway.
        let content = "Here is your report\nMEDIA:http://localhost:8642/v1/files/s1/report.pdf"
        let atts = MediaParser.extractAttachments(from: content) { raw in
            raw.replacingOccurrences(of: "localhost:8642", with: "gw.example.com")
        }
        let att = try #require(atts.first)
        guard case .remote(let url) = att.source else {
            Issue.record("expected a remote attachment")
            return
        }
        #expect(url.absoluteString == "http://gw.example.com/v1/files/s1/report.pdf")
        #expect(att.fileName == "report.pdf")
    }

    @Test("The resolver is applied before the URL is built, for videos too")
    internal func remoteVideoResolved() throws {
        let content = "MEDIA:http://127.0.0.1:8642/v1/files/s1/clip.mp4"
        let atts = MediaParser.extractAttachments(from: content) { raw in
            raw.replacingOccurrences(of: "127.0.0.1:8642", with: "gw.example.com")
        }
        let att = try #require(atts.first)
        #expect(att.path == "http://gw.example.com/v1/files/s1/clip.mp4")
        #expect(att.fileExtension == "mp4")
    }

    @Test("Without a resolver the URL passes through unchanged (default identity)")
    internal func defaultResolverIsIdentity() throws {
        let content = "MEDIA:https://cdn.example.com/a/b/doc.pdf"
        let atts = MediaParser.extractAttachments(from: content)
        let att = try #require(atts.first)
        #expect(att.path == "https://cdn.example.com/a/b/doc.pdf")
    }

    @Test("A non-loopback URL is untouched even when a resolver is supplied")
    internal func resolverLeavesNonLoopbackAlone() throws {
        // Mirrors GatewayClient.resolvedMediaURL semantics: only loopback hosts
        // are rewritten; a real host returns the input verbatim.
        let content = "MEDIA:https://real.example.com/v1/files/s1/x.pdf"
        let atts = MediaParser.extractAttachments(from: content) { raw in
            raw.contains("localhost") ? "http://gw/x" : raw
        }
        #expect(atts.first?.path == "https://real.example.com/v1/files/s1/x.pdf")
    }

    // MARK: - Line matching (regressions guarded)

    @Test("Only standalone MEDIA: lines match, not prose mentions")
    internal func onlyStandaloneLinesMatch() {
        let content = "talk about MEDIA:foo in a sentence\nand more text"
        #expect(MediaParser.extractAttachments(from: content).isEmpty)
    }

    @Test("Multiple MEDIA lines each yield an attachment, each resolved")
    internal func multipleRemoteLines() {
        let content = """
        MEDIA:http://localhost:8642/v1/files/s1/a.pdf
        MEDIA:http://localhost:8642/v1/files/s1/b.mp4
        """
        let atts = MediaParser.extractAttachments(from: content) { raw in
            raw.replacingOccurrences(of: "localhost:8642", with: "host")
        }
        #expect(atts.count == 2)
        #expect(atts.allSatisfy { $0.path.hasPrefix("http://host/") })
    }

    @Test("Resumed gateway history reconstructs remote video attachments")
    internal func resumedHistoryReconstructsVideoAttachment() throws {
        let raw: [[String: AnyCodable]] = [[
            "role": AnyCodable("assistant"),
            "text": AnyCodable("Your clip\nMEDIA:https://gateway.example/v1/files/s1/clip.mp4"),
        ]]

        let message = try #require(ChatViewModel.parseHistoryMessages(raw).first)
        let attachment = try #require(message.attachments.first)
        #expect(attachment.category == .video)
        #expect(attachment.path == "https://gateway.example/v1/files/s1/clip.mp4")
    }

    @Test("History merge preserves locally cached attachment identity")
    internal func historyMergePreservesLocalAttachment() throws {
        let content = "Your clip\nMEDIA:https://gateway.example/v1/files/s1/clip.mp4"
        let gateway = ChatMessage(role: .assistant, content: content, status: "complete")
        var local = ChatMessage(role: .assistant, content: content, status: "complete")
        local.attachments = [try #require(MediaParser.extractAttachments(from: content).first)]

        let message = try #require(ChatViewModel.mergeHistory(gateway: [gateway], local: [local]).first)
        let attachment = try #require(message.attachments.first)
        #expect(attachment.id == local.attachments[0].id)
        #expect(attachment.category == .video)
    }

    // MARK: - stripMediaTags (unchanged behavior, guarded)

    @Test("stripMediaTags removes MEDIA lines and trims")
    internal func stripsMediaTags() {
        let content = "Summary text\nMEDIA:http://localhost:8642/v1/files/s1/a.pdf"
        #expect(MediaParser.stripMediaTags(from: content) == "Summary text")
    }
}
