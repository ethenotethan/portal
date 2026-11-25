#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import Portal

// The pin script against a real document: where pins land, what happens when
// the markup under them changes, and that a script-made click cannot place
// one. Runs the same source and the same isolated world the app injects.

@MainActor
private final class Page: NSObject, WKNavigationDelegate {
    internal let webView: WKWebView
    internal private(set) var requests: [HTMLArtifactCommentRequest] = []
    private let nonce = "page-test-nonce"
    private let world = WKContentWorld.world(name: HTMLArtifactCommentBridge.contentWorldName)
    private var loaded: CheckedContinuation<Void, Never>?

    internal init(html: String) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        configuration.userContentController.addUserScript(WKUserScript(
            source: HTMLArtifactCommentBridge.userScriptSource(nonce: nonce),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    internal func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        loaded?.resume()
        loaded = nil
    }

    internal func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.scheme == HTMLArtifactCommentRequest.scheme {
            if let request = HTMLArtifactCommentRequest(url: url, expectedNonce: nonce) { requests.append(request) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    internal func apply(_ state: HTMLArtifactCommentBridge.PageState) async throws {
        _ = try await webView.evaluateJavaScript(
            HTMLArtifactCommentBridge.applyScript(state) + " null", in: nil, contentWorld: world)
    }

    /// Run `body` (a function body) in the page's own world or the bridge's.
    internal func run(_ body: String, inBridgeWorld: Bool = true) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: inBridgeWorld ? world : .page)
    }

    /// Visible pins as "number@left,top", in document order.
    internal func pins() async throws -> [String] {
        let value = try await run("""
            return Array.from(document.querySelectorAll('[data-hermes-comment-pin]'))
              .filter((pin) => pin.style.display !== 'none')
              .map((pin) => pin.textContent + '@' + Math.round(parseFloat(pin.style.left)) + ',' + Math.round(parseFloat(pin.style.top)));
            """)
        return value as? [String] ?? []
    }
}

@Suite("Artifact comment pins in a page")
@MainActor
internal struct ArtifactCommentPageTests {
    private let html = """
        <!doctype html><html><body style="margin:0">
        <h1 style="margin:0;height:40px">Q3 report</h1>
        <p id="intro" style="margin:0;height:20px">Intro</p>
        <table style="position:absolute;left:100px;top:200px;width:400px;height:100px"><tr><td>Revenue by region</td></tr></table>
        </body></html>
        """

    private func pin(_ id: String, _ number: Int, selector: String, x: Double = 0.5, y: Double = 0.5,
                     text: String = "", resolved: Bool = false) -> HTMLArtifactCommentBridge.Pin {
        HTMLArtifactCommentBridge.Pin(
            id: id, number: number,
            anchor: ArtifactCommentAnchor(selector: selector, x: x, y: y, text: text), resolved: resolved)
    }

    @Test("A pin lands at its fraction of the anchored element's box")
    internal func pinLandsOnItsElement() async throws {
        let page = await Page(html: html)
        try await page.apply(HTMLArtifactCommentBridge.PageState(pins: [
            pin("c-1", 1, selector: "body > table:nth-of-type(1)", x: 0.25, y: 0.5, text: "Revenue by region"),
            pin("c-2", 2, selector: "#intro", x: 0, y: 0, text: "Intro"),
        ]))
        #expect(try await page.pins() == ["1@200,250", "2@0,40"])
    }

    @Test("A pin follows its text when the element moves, and hides when the anchor is gone")
    internal func pinFollowsTextThenDetaches() async throws {
        let page = await Page(html: html)
        let state = HTMLArtifactCommentBridge.PageState(pins: [pin("c-2", 2, selector: "#intro", x: 0, y: 0, text: "Intro")])
        try await page.apply(state)
        #expect(try await page.pins() == ["2@0,40"])

        // The agent rewrote the page: the paragraph lost its id and moved down.
        _ = try await page.run("""
            const intro = document.getElementById('intro');
            intro.removeAttribute('id');
            intro.style.cssText = 'position:absolute;left:30px;top:400px;margin:0;height:20px;width:100px';
            """, inBridgeWorld: false)
        try await page.apply(state)
        #expect(try await page.pins() == ["2@30,400"])

        _ = try await page.run("document.querySelector('p').remove();", inBridgeWorld: false)
        try await page.apply(state)
        #expect(try await page.pins().isEmpty)
    }

    @Test("Pins that leave the state leave the page, and comment text never enters it")
    internal func pinsAreRemovedAndCarryOnlyNumbers() async throws {
        let page = await Page(html: html)
        try await page.apply(HTMLArtifactCommentBridge.PageState(selectedID: "c-1", pins: [
            pin("c-1", 7, selector: "#intro", text: "Intro", resolved: true),
        ]))
        let text = try await page.run("return document.querySelector('[data-hermes-comment-layer]').innerText;")
        #expect((text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "7")

        try await page.apply(HTMLArtifactCommentBridge.PageState())
        #expect(try await page.pins().isEmpty)
    }

    @Test("Placing mode marks the document, and a click made by page script cannot place a pin")
    internal func scriptedClicksCannotPlace() async throws {
        let page = await Page(html: html)
        try await page.apply(HTMLArtifactCommentBridge.PageState(isPlacing: true))
        let marked = try await page.run("return document.documentElement.hasAttribute('data-hermes-commenting');")
        #expect(marked as? Bool == true)

        _ = try await page.run("document.getElementById('intro').click();", inBridgeWorld: false)
        _ = try await page.run("return 1;")
        #expect(page.requests.isEmpty)

        try await page.apply(HTMLArtifactCommentBridge.PageState())
        let cleared = try await page.run("return document.documentElement.hasAttribute('data-hermes-commenting');")
        #expect(cleared as? Bool == false)
    }

    @Test("The page cannot reach the bridge or its nonce")
    internal func bridgeIsInvisibleToThePage() async throws {
        let page = await Page(html: html)
        let seen = try await page.run("return typeof globalThis.__hermesComments;", inBridgeWorld: false)
        #expect(seen as? String == "undefined")
    }
}
#endif
