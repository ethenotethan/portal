import SwiftUI
import WebKit

/// Renders a Mermaid diagram inside a WKWebView using mermaid.js from CDN.
/// Falls back to raw code display if rendering fails.
struct MermaidDiagramView: View {
    let mermaidCode: String
    var isInteractive: Bool = false

    var body: some View {
        #if os(macOS)
        MermaidDiagramNSView(mermaidCode: mermaidCode, isInteractive: isInteractive)
        #else
        MermaidDiagramUIView(mermaidCode: mermaidCode, isInteractive: isInteractive)
        #endif
    }
}

#if os(macOS)
struct MermaidDiagramNSView: NSViewRepresentable {
    let mermaidCode: String
    let isInteractive: Bool

    func makeNSView(context: Context) -> MermaidWebView {
        MermaidWebView()
    }

    func updateNSView(_ webView: MermaidWebView, context: Context) {
        webView.render(mermaidCode: mermaidCode, isInteractive: isInteractive)
    }
}
#else
struct MermaidDiagramUIView: UIViewRepresentable {
    let mermaidCode: String
    let isInteractive: Bool

    func makeUIView(context: Context) -> MermaidWebView {
        MermaidWebView()
    }

    func updateUIView(_ webView: MermaidWebView, context: Context) {
        webView.render(mermaidCode: mermaidCode, isInteractive: isInteractive)
    }
}
#endif

/// WKWebView subclass that loads mermaid.js from CDN and renders diagrams.
/// Detects system appearance for dark/light theme.
class MermaidWebView: WKWebView {
    private var currentCode: String = ""
    private var currentInteractive = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        #if os(macOS)
        setValue(false, forKey: "drawsBackground")
        #else
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        #endif
        navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(mermaidCode: String, isInteractive: Bool = false) {
        guard mermaidCode != currentCode || isInteractive != currentInteractive else { return }
        currentCode = mermaidCode
        currentInteractive = isInteractive
        #if os(macOS)
        allowsMagnification = isInteractive
        magnification = 1.0
        #endif
        let html = buildHTML(mermaidCode: mermaidCode, isInteractive: isInteractive)
        loadHTMLString(html, baseURL: nil)
    }

    private func buildHTML(mermaidCode: String, isInteractive: Bool) -> String {
        let escaped = mermaidCode
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")

        let interactiveClass = isInteractive ? "interactive" : "preview"
        let bodyPadding = isInteractive ? 24 : 10
        let bodyOverflow = isInteractive ? "auto" : "hidden"
        let hint = isInteractive ? "<div class=\"hint\">drag/scroll to pan · ⌘/+/- to zoom</div>" : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body {
                width: 100%;
                min-height: 100%;
            }
            body {
                margin: 0;
                padding: \(bodyPadding)px;
                background: transparent;
                color: #e0e0e0;
                font-family: -apple-system, system-ui, sans-serif;
                overflow: \(bodyOverflow);
            }
            #viewport.interactive {
                min-width: max-content;
                min-height: max-content;
                transform-origin: 0 0;
                cursor: grab;
            }
            #viewport.interactive.dragging { cursor: grabbing; }
            #container { text-align: center; min-width: max-content; }
            .preview svg { max-width: 100%; height: auto; }
            .interactive svg {
                max-width: none;
                height: auto;
                min-width: 100%;
            }
            .error { color: #ff6b6b; font-family: monospace; font-size: 11px; white-space: pre-wrap; text-align: left; }
            .loading { color: #888; font-size: 12px; }
            .hint {
                position: fixed;
                right: 14px;
                bottom: 12px;
                padding: 5px 8px;
                border-radius: 999px;
                background: rgba(42, 42, 42, 0.82);
                color: #9a9a9a;
                font-size: 11px;
                pointer-events: none;
            }
        </style>
        </head>
        <body>
        <div id="viewport" class="\(interactiveClass)"><div id="container"><span class="loading">Rendering diagram…</span></div></div>
        \(hint)
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <script>
        const code = `\(escaped)`;
        const interactive = \(isInteractive ? "true" : "false");
        let scale = 1;
        let panX = 0;
        let panY = 0;
        const viewport = document.getElementById('viewport');

        function applyTransform() {
            if (!interactive) return;
            viewport.style.transform = `translate(${panX}px, ${panY}px) scale(${scale})`;
        }

        function setScale(nextScale, originX = 0, originY = 0) {
            const oldScale = scale;
            scale = Math.max(0.2, Math.min(4, nextScale));
            if (scale === oldScale) return;
            panX = originX - ((originX - panX) * (scale / oldScale));
            panY = originY - ((originY - panY) * (scale / oldScale));
            applyTransform();
        }

        if (interactive) {
            document.addEventListener('wheel', (event) => {
                if (event.metaKey || event.ctrlKey) {
                    event.preventDefault();
                    const factor = event.deltaY < 0 ? 1.1 : 0.9;
                    setScale(scale * factor, event.clientX, event.clientY);
                }
            }, { passive: false });

            let dragging = false;
            let lastX = 0;
            let lastY = 0;
            viewport.addEventListener('mousedown', (event) => {
                if (event.button !== 0) return;
                dragging = true;
                lastX = event.clientX;
                lastY = event.clientY;
                viewport.classList.add('dragging');
            });
            window.addEventListener('mousemove', (event) => {
                if (!dragging) return;
                panX += event.clientX - lastX;
                panY += event.clientY - lastY;
                lastX = event.clientX;
                lastY = event.clientY;
                applyTransform();
            });
            window.addEventListener('mouseup', () => {
                dragging = false;
                viewport.classList.remove('dragging');
            });

            document.addEventListener('keydown', (event) => {
                if (!(event.metaKey || event.ctrlKey)) return;
                if (event.key === '+' || event.key === '=') {
                    event.preventDefault();
                    setScale(scale * 1.15, window.innerWidth / 2, window.innerHeight / 2);
                } else if (event.key === '-') {
                    event.preventDefault();
                    setScale(scale * 0.85, window.innerWidth / 2, window.innerHeight / 2);
                } else if (event.key === '0') {
                    event.preventDefault();
                    scale = 1; panX = 0; panY = 0; applyTransform();
                }
            });
        }

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
                    const h = document.getElementById('container').scrollHeight;
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.resize) {
                            window.webkit.messageHandlers.resize.postMessage({ height: h });
                        }
                    } catch(e) {}
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
        guard !currentInteractive else { return }
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
