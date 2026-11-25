import WebKit

/// The comment half of the HTML artifact web view: installing the pin script,
/// keeping the page's pins in step with the host, and receiving the page's
/// place/open requests. Kept beside the delegate rather than in it; the
/// delegate only stores the two values this reads.
extension HTMLNavigationDelegate {
    /// Install the pin script for a live artifact. Transcript and revision
    /// HTML pass `enabled: false` and get none.
    internal func installCommentScript(into configuration: WKWebViewConfiguration, enabled: Bool) {
        guard enabled else { return }
        configuration.userContentController.addUserScript(WKUserScript(
            source: HTMLArtifactCommentBridge.userScriptSource(nonce: nonce),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: WKContentWorld.world(name: HTMLArtifactCommentBridge.contentWorldName)
        ))
    }

    /// Bring the page's pins and placing mode to what the host wants, only
    /// when that differs from what is already there.
    internal func applyComments(to webView: WKWebView) {
        let desired = comments?.state
        guard desired != appliedCommentState else { return }
        appliedCommentState = desired
        webView.evaluateJavaScript(
            HTMLArtifactCommentBridge.applyScript(desired ?? HTMLArtifactCommentBridge.PageState()),
            in: nil,
            in: WKContentWorld.world(name: HTMLArtifactCommentBridge.contentWorldName)
        ) { _ in }
    }

    /// True when `url` is the comment scheme, which is always a control
    /// message and never a page navigation, valid or not.
    internal func handleCommentNavigation(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == HTMLArtifactCommentRequest.scheme else { return false }
        if let request = HTMLArtifactCommentRequest(url: url, expectedNonce: nonce) {
            comments?.onRequest(request)
        }
        return true
    }
}
