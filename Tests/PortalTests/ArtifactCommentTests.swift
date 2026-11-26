import Foundation
import Testing
@testable import Portal

// Comments pinned to an HTML artifact: the wire model, the page→native
// request contract, the pins native asks the page to draw, the event and the
// capability flag. Pure values; the script's behaviour in a real document is
// in ArtifactCommentPageTests.

@Suite("Artifact comments")
internal struct ArtifactCommentTests {
    private static let nonce = "N0NCE"

    private func url(_ host: String, _ items: [(String, String)]) -> URL {
        var components = URLComponents()
        components.scheme = HTMLArtifactCommentRequest.scheme
        components.host = host
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    private func place(_ overrides: [String: String] = [:], drop: String? = nil) -> HTMLArtifactCommentRequest? {
        var fields = [
            "selector": "body > table:nth-of-type(1)", "x": "0.2500", "y": "0.7500",
            "text": "Revenue by region", "nonce": Self.nonce,
        ]
        for (name, value) in overrides { fields[name] = value }
        if let drop { fields.removeValue(forKey: drop) }
        return HTMLArtifactCommentRequest(
            url: url("place", fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }),
            expectedNonce: Self.nonce)
    }

    // MARK: - Page → native

    @Test("A place request carries the clicked element, the spot inside it and its text")
    internal func placeRequestParses() {
        #expect(place() == .place(ArtifactCommentAnchor(
            selector: "body > table:nth-of-type(1)", x: 0.25, y: 0.75, text: "Revenue by region")))
    }

    @Test("A pin click opens that comment")
    internal func openRequestParses() {
        let request = HTMLArtifactCommentRequest(
            url: url("open", [("comment_id", "c-4f1c0a9be2d7"), ("nonce", Self.nonce)]),
            expectedNonce: Self.nonce)
        #expect(request == .open(commentID: "c-4f1c0a9be2d7"))
    }

    @Test("A request without this web view's nonce is refused")
    internal func nonceIsRequired() {
        #expect(place(["nonce": "other"]) == nil)
        #expect(place(drop: "nonce") == nil)
        #expect(HTMLArtifactCommentRequest(
            url: url("place", [("selector", "body"), ("x", "0"), ("y", "0"), ("nonce", "")]),
            expectedNonce: "") == nil)
    }

    @Test("Malformed place requests are refused", arguments: [
        ["x": "1.5"], ["y": "-0.1"], ["x": "left"], ["selector": ""],
        ["selector": String(repeating: "s", count: 513)],
        ["text": String(repeating: "t", count: 281)],
        ["text": "line\u{0000}break"], ["selector": "a\u{0007}b"],
    ])
    internal func malformedPlaceIsRefused(overrides: [String: String]) {
        #expect(place(overrides) == nil)
    }

    @Test("Unknown hosts, unknown fields, repeated fields and bad ids are refused")
    internal func unexpectedShapesAreRefused() {
        let good = [("selector", "body"), ("x", "0.5"), ("y", "0.5"), ("nonce", Self.nonce)]
        #expect(HTMLArtifactCommentRequest(url: url("place", good), expectedNonce: Self.nonce) != nil)
        #expect(HTMLArtifactCommentRequest(url: url("delete", good), expectedNonce: Self.nonce) == nil)
        #expect(HTMLArtifactCommentRequest(
            url: url("place", good + [("body", "typed by the page")]), expectedNonce: Self.nonce) == nil)
        #expect(HTMLArtifactCommentRequest(
            url: url("place", good + [("x", "0.1")]), expectedNonce: Self.nonce) == nil)
        #expect(HTMLArtifactCommentRequest(
            url: url("open", [("comment_id", "c 1"), ("nonce", Self.nonce)]), expectedNonce: Self.nonce) == nil)
        #expect(HTMLArtifactCommentRequest(
            url: URL(string: "https://example.com/place?nonce=\(Self.nonce)") ?? URL(fileURLWithPath: "/"),
            expectedNonce: Self.nonce) == nil)
    }

    // MARK: - Native → page

    private func comment(_ id: String, selector: String = "body > p", resolved: Bool = false) -> ArtifactComment {
        ArtifactComment(
            id: id, artifactID: "report", rev: 3,
            anchor: ArtifactCommentAnchor(selector: selector, x: 0.5, y: 0.5, text: "t"),
            author: "app:1A2B", body: "note", createdAt: Date(timeIntervalSince1970: 0),
            resolved: resolved, resolvedBy: resolved ? "agent:s1" : "")
    }

    @Test("Open comments with a spot become pins numbered by their place in the list")
    internal func pinsKeepTheirNumbers() {
        let comments = [comment("a"), comment("b", resolved: true), comment("c", selector: ""), comment("d")]
        let pins = HTMLArtifactCommentBridge.pins(for: comments, selectedID: nil)
        #expect(pins.map(\.id) == ["a", "d"])
        #expect(pins.map(\.number) == [1, 4])
    }

    @Test("A selected resolved comment still shows its pin")
    internal func selectedResolvedCommentIsDrawn() {
        let pins = HTMLArtifactCommentBridge.pins(
            for: [comment("a"), comment("b", resolved: true)], selectedID: "b")
        #expect(pins.map(\.id) == ["a", "b"])
        #expect(pins.last?.resolved == true)
    }

    @Test("The apply call carries the state as JSON that page text cannot break out of")
    internal func applyScriptEncodesState() {
        let hostile = ArtifactCommentAnchor(selector: "p[title=\"x\"]", x: 0.1, y: 0.9, text: "</script>'\";alert(1)")
        let js = HTMLArtifactCommentBridge.applyScript(HTMLArtifactCommentBridge.PageState(
            isPlacing: true, selectedID: "c-1",
            pins: [HTMLArtifactCommentBridge.Pin(id: "c-1", number: 2, anchor: hostile, resolved: false)]))
        #expect(js.hasPrefix("globalThis.__hermesComments && globalThis.__hermesComments.apply({"))
        #expect(js.contains("\"placing\":true"))
        #expect(js.contains("\"selected\":\"c-1\""))
        #expect(js.contains("\"n\":2"))
        #expect(js.contains("<\\/script>"))
        #expect(!js.contains("</script>"))
        #expect(js.contains("p[title=\\\"x\\\"]"))
    }

    @Test("The page script holds the nonce, accepts only trusted clicks and writes no comment text")
    internal func userScriptIsScoped() {
        let js = HTMLArtifactCommentBridge.userScriptSource(nonce: "abc\"def")
        #expect(js.contains("const nonce = \"abc\\\"def\";"))
        #expect(js.contains("event.isTrusted"))
        #expect(js.contains("hermes-artifact-comment://"))
        #expect(js.contains("encodeURIComponent"))
        #expect(!js.contains("innerHTML"))
        #expect(!js.contains("fetch("))
        #expect(!js.contains("eval("))
        #expect(!js.contains("__NONCE__"))
    }

    // MARK: - Wire model, event, capability

    @Test("A comment decodes from the gateway's record")
    internal func commentDecodes() {
        let decoded = ArtifactComment.from([
            "id": .string("c-1"), "artifact_id": .string("report"), "rev": .int(7),
            "anchor": .dictionary([
                "selector": .string("body > table"), "x": .double(0.42), "y": .int(1), "text": .string("Revenue"),
            ]),
            "author": .string("app:1A2B"), "body": .string("Stale totals."),
            "created_at": .string("2026-11-26T09:14:03+00:00"),
            "resolved": .bool(true), "resolved_by": .string("agent:s1"),
        ])
        #expect(decoded?.rev == 7)
        #expect(decoded?.anchor == ArtifactCommentAnchor(selector: "body > table", x: 0.42, y: 1, text: "Revenue"))
        #expect(decoded?.resolvedByAgent == true)
        #expect(decoded?.createdAt == Date(timeIntervalSince1970: 1_795_684_443))
        #expect(ArtifactComment.from(["body": .string("no id")]) == nil)
    }

    @Test("An anchor without a selector is a comment on the whole artifact and sends no anchor")
    internal func wholeArtifactAnchor() {
        let whole = ArtifactComment.from(["id": .string("c-2"), "anchor": .dictionary([:])])
        #expect(whole?.anchor.isWholeArtifact == true)
        #expect(whole?.anchor.wire.isEmpty == true)
        let pinned = ArtifactCommentAnchor(selector: "body", x: 0.1, y: 0.2, text: "")
        #expect(pinned.wire == ["selector": .string("body"), "x": .double(0.1), "y": .double(0.2)])
    }

    @Test("artifact.comment.changed parses into its event")
    internal func commentChangedEvent() {
        let event = GatewayEvent.from(type: "artifact.comment.changed", payload: .dictionary([
            "artifact_id": .string("report"), "comment_id": .string("c-1"),
            "change": .string("resolved"), "open": .int(2),
        ]))
        guard case .artifactCommentChanged(let artifactID, let commentID, let change, let open) = event else {
            Issue.record("expected artifactCommentChanged, got \(event.debugName)")
            return
        }
        #expect(artifactID == "report")
        #expect(commentID == "c-1")
        #expect(change == "resolved")
        #expect(open == 2)
        #expect(event.debugName == "artifact.comment.changed")
    }

    @Test("Comment controls appear only when the gateway advertises artifact.comment")
    internal func commentCapability() {
        func capabilities(_ names: Set<String>) -> GatewayCapabilities {
            GatewayCapabilities(
                gatewayVersion: nil, agentVersion: nil, capabilityNames: names,
                hasImageInput: false, hasACPImagePrompts: false,
                source: .gateway(method: "gateway.capabilities"))
        }
        #expect(capabilities(["artifact.comment"]).supportsArtifactComments)
        #expect(capabilities(["artifact_comment_add"]).supportsArtifactComments)
        #expect(!capabilities(["artifact.action.invoke", "artifact.query"]).supportsArtifactComments)
    }
}
