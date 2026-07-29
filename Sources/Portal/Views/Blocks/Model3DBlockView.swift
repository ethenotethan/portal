import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "Model3DBlockView")

/// Renders a `model3d` living artifact. Parses the artifact content JSON,
/// generates a Three.js HTML document via `Model3DTemplate`, and loads it
/// into a WKWebView with JavaScript enabled.
struct Model3DBlockView: View {
    let json: String
    let isStreaming: Bool

    var body: some View {
        ZStack {
            Theme.background
            Model3DWebView(html: html)
        }
        .frame(minHeight: 360)
    }

    private var html: String {
        if let spec = Model3DTemplate.parse(json) {
            return Model3DTemplate.render(spec)
        }
        // Parse error — show a friendly message
        return Self.errorHTML(message: "Could not parse model3d artifact. Expected JSON with 'format', and 'data' (base64) or 'url'.")
    }

    private static func errorHTML(message: String) -> String {
        """
        <html><body style="margin:0;display:flex;align-items:center;justify-content:center;\
        height:100vh;background:#1a1a2e;color:#888;font-family:-apple-system,sans-serif;\
        font-size:13px;text-align:center;padding:20px;">\(message)</body></html>
        """
    }
}

/// Platform-agnostic WKWebView wrapper for 3D rendering.
struct Model3DWebView: View {
    let html: String

    var body: some View {
        #if os(macOS)
        Model3DNSView(html: html)
        #else
        Model3DUIView(html: html)
        #endif
    }
}

#if os(macOS)
struct Model3DNSView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if content changed — avoids restarting the WebGL loop
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
    }
}
#else
struct Model3DUIView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
    }
}
#endif
