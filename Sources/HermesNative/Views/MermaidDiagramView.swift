import SwiftUI
import WebKit

/// Renders a Mermaid diagram inside a WKWebView using mermaid.js from CDN.
/// Falls back to raw code display if rendering fails.
struct MermaidDiagramView: NSViewRepresentable {
    let mermaidCode: String

    func makeNSView(context: Context) -> MermaidWebView {
        MermaidWebView()
    }

    func updateNSView(_ webView: MermaidWebView, context: Context) {
        webView.render(mermaidCode: mermaidCode)
    }
}

/// WKWebView subclass that loads mermaid.js from CDN and renders diagrams.
/// Detects system appearance for dark/light theme.
class MermaidWebView: WKWebView {
    private var currentCode: String = ""

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        setValue(false, forKey: "drawsBackground")
        navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(mermaidCode: String) {
        guard mermaidCode != currentCode else { return }
        currentCode = mermaidCode
        let html = buildHTML(mermaidCode: mermaidCode)
        loadHTMLString(html, baseURL: nil)
    }

    private func buildHTML(mermaidCode: String) -> String {
        // Escape for JS template literal
        let escaped = mermaidCode
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            body {
                margin: 0;
                padding: 10px;
                background: transparent;
                color: #e0e0e0;
                font-family: -apple-system, system-ui, sans-serif;
            }
            #container { text-align: center; }
            svg { max-width: 100%; height: auto; }
            .error { color: #ff6b6b; font-family: monospace; font-size: 11px; white-space: pre-wrap; text-align: left; }
            .loading { color: #888; font-size: 12px; }
        </style>
        </head>
        <body>
        <div id="container"><span class="loading">Rendering diagram…</span></div>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <script>
        const code = `\(escaped)`;

        if (typeof mermaid !== 'undefined') {
            mermaid.initialize({
                startOnLoad: false,
                theme: 'dark',
                securityLevel: 'loose',
                flowchart: { htmlLabels: true, curve: 'basis' },
                sequence: { useMaxWidth: true },
            });

            async function render() {
                try {
                    const { svg } = await mermaid.render('mermaid-svg', code);
                    document.getElementById('container').innerHTML = svg;
                    // Notify native side of rendered height
                    const h = document.getElementById('container').scrollHeight;
                    window.webkit.messageHandlers.resize?.postMessage({ height: h });
                } catch (err) {
                    document.getElementById('container').innerHTML =
                        '<div class="error">Mermaid: ' + err.message.replace(/</g, '&lt;') + '</div>';
                }
            }
            render();
        } else {
            document.getElementById('container').innerHTML =
                '<div class="error">Failed to load mermaid.js — check network</div>';
        }
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - Navigation Delegate (auto-size)

extension MermaidWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        evaluateRenderedHeight()
    }

    private func evaluateRenderedHeight() {
        // Poll for the rendered SVG height — mermaid renders async
        let js = "document.getElementById('container').scrollHeight"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.evaluateJavaScript(js) { height, _ in
                guard let h = height as? CGFloat, h > 0 else { return }
                self?.frame.size.height = h + 20
                self?.invalidateIntrinsicContentSize()
            }
        }
        // Second pass after SVG fully settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.evaluateJavaScript(js) { height, _ in
                guard let h = height as? CGFloat, h > 0 else { return }
                self?.frame.size.height = h + 20
                self?.invalidateIntrinsicContentSize()
            }
        }
    }
}
