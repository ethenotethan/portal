import SwiftUI
import BeautifulMermaid
import WebKit
import os

private let log = Logger(
    subsystem: "com.researchoors.HermesNative",
    category: "MermaidDiagramView"
)

private let nativeDiagramTypes: Set<String> = [
    "flowchart", "graph", "sequence", "sequencediagram", "sequenceDiagram",
    "class", "classDiagram", "classdiagram",
    "er", "erDiagram", "erdiagram",
    "xychart", "xyChart", "xychart-beta",
]

private let knownDiagramKeywords: Set<String> = [
    "flowchart", "graph", "sequenceDiagram", "sequence", "stateDiagram",
    "classDiagram", "classDiagram-v2", "erDiagram",
    "gantt", "pie", "mindmap", "timeline", "gitgraph",
    "sankey", "block", "block-beta", "quadrantChart",
    "radar", "treemap", "xychart", "xychart-beta", "journey",
    "requirementDiagram", "c4Context", "c4Container", "c4Deployment",
    "c4Dynamic", "packet",
]

struct MermaidDiagramView: View {
    let mermaidCode: String

    var body: some View {
        MermaidRendererCoordinator(source: mermaidCode)
    }
}

// MARK: - Coordinator

private struct MermaidRendererCoordinator: View {
    let source: String
    @State private var useFallback = false

    private var cleanedSource: String {
        let s = source
            .replacingOccurrences(of: "```mermaid", with: "")
            .replacingOccurrences(of: "```flowchart", with: "")
            .replacingOccurrences(of: "```sequenceDiagram", with: "")
            .replacingOccurrences(of: "```stateDiagram", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    private var diagramType: String? {
        let firstLine = cleanedSource.split(separator: "\n").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        for keyword in knownDiagramKeywords where firstLine.hasPrefix(keyword.lowercased()) {
            return keyword
        }
        return nil
    }

    private var isNativeSupported: Bool {
        guard let type = diagramType else { return true }
        return nativeDiagramTypes.contains(type)
    }

    var body: some View {
        if useFallback || !isNativeSupported {
            WebMermaidRenderer(source: cleanedSource)
        } else {
            NativeMermaidRenderer(source: cleanedSource) {
                useFallback = true
            }
        }
    }
}

// MARK: - Native Renderer

private struct NativeMermaidRenderer: View {
    let source: String
    let onFallback: () -> Void

    @State private var image: PlatformImage?
    @State private var errorText: String?
    @State private var didFallBack = false

    private var asciiSource: String {
        source.unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
    }

    var body: some View {
        Group {
            if let image {
                ZoomableDiagram(image: image)
            } else if let error = errorText {
                ErrorCard(error: error, source: source)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Rendering diagram…")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
                .onAppear(perform: render)
            }
        }
    }

    private func render() {
        let code = asciiSource
        guard !code.isEmpty else {
            errorText = "Empty source after cleaning fences"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let positioned = try MermaidRenderer.layout(code)
                guard let img = renderPositioned(positioned, scale: 2.0) else {
                    DispatchQueue.main.async {
                        errorText = "renderPositioned returned nil"
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.image = img
                }
            } catch {
                log.warning("Native mermaid failed, falling back to web renderer: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if !didFallBack {
                        didFallBack = true
                        onFallback()
                    }
                }
            }
        }
    }

    private nonisolated func renderPositioned(_ positioned: PositionedGraph, scale: CGFloat) -> PlatformImage? {
        let bounds = CGRect(
            x: 0, y: 0,
            width: max(1, positioned.width),
            height: max(1, positioned.height)
        )
        let pixelSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let w = Int(pixelSize.width)
        let h = Int(pixelSize.height)
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }

        ctx.setFillColor(nativeTheme.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pixelSize))

        ctx.scaleBy(x: scale, y: scale)

        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        DiagramRenderer(theme: nativeTheme).render(positioned, in: ctx, bounds: bounds)

        guard let cgImage = ctx.makeImage() else { return nil }

        #if os(macOS)
        return NSImage(cgImage: cgImage, size: bounds.size)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

// MARK: - Web (WKWebView) Fallback Renderer

private struct WebMermaidRenderer: View {
    let source: String
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let error = errorMessage {
                ErrorCard(error: error, source: source)
            } else {
                ZStack {
                    MermaidWebView(source: source, isLoading: $isLoading, onError: { msg in
                        errorMessage = msg
                    })
                    if isLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Rendering diagram…")
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
        }
    }
}

#if os(macOS)
private struct MermaidWebView: NSViewRepresentable {
    let source: String
    @Binding var isLoading: Bool
    let onError: (String) -> Void

    private func makeHTML() -> String {
        let escaped = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "</", with: "<\\/")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { background: #1a1a1a; width: 100%; height: 100%; overflow: auto; }
          .mermaid-container { display: flex; justify-content: center; padding: 16px; min-height: 100%; }
          .mermaid { max-width: none; }
        </style>
        </head>
        <body>
        <div class="mermaid-container">
          <pre class="mermaid" id="diagram">
        \(escaped)
          </pre>
        </div>
        <script>
          mermaid.initialize({
            startOnLoad: true,
            theme: 'dark',
            themeVariables: {
              primaryColor: '#7c7cff',
              primaryTextColor: '#f0f0f0',
              primaryBorderColor: '#7c7cff',
              lineColor: '#7c7cff',
              background: '#1a1a1a',
              mainBkg: '#2a2a2a',
              nodeBorder: '#7c7cff',
              clusterBkg: '#2a2a2a',
              titleColor: '#f0f0f0',
              textColor: '#f0f0f0',
            },
            fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
          });
          document.addEventListener('DOMContentLoaded', function() {
            setTimeout(function() { window.webkit.messageHandlers.mermaidDone.postMessage('ok'); }, 1500);
          });
          window.onerror = function(msg, url, line) {
            window.webkit.messageHandlers.mermaidError.postMessage(msg);
          };
        </script>
        </body>
        </html>
        """
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mermaidDone")
        config.userContentController.add(context.coordinator, name: "mermaidError")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(makeHTML(), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: MermaidWebView

        init(parent: MermaidWebView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "mermaidDone" {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isLoading = false
                }
            } else if message.name == "mermaidError" {
                let msg = message.body as? String ?? "Unknown error"
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onError("Web renderer error: \(msg)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.parent.isLoading == true {
                    self?.parent.isLoading = false
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onError("Failed to load mermaid.js: \(error.localizedDescription)")
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onError("Failed to load mermaid.js: \(error.localizedDescription)")
            }
        }
    }
}
#else
private struct MermaidWebView: UIViewRepresentable {
    let source: String
    @Binding var isLoading: Bool
    let onError: (String) -> Void

    private func makeHTML() -> String {
        let escaped = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "</", with: "<\\/")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { background: #1a1a1a; width: 100%; height: 100%; overflow: auto; }
          .mermaid-container { display: flex; justify-content: center; padding: 16px; min-height: 100%; }
          .mermaid { max-width: none; }
        </style>
        </head>
        <body>
        <div class="mermaid-container">
          <pre class="mermaid" id="diagram">
        \(escaped)
          </pre>
        </div>
        <script>
          mermaid.initialize({
            startOnLoad: true,
            theme: 'dark',
            themeVariables: {
              primaryColor: '#7c7cff',
              primaryTextColor: '#f0f0f0',
              primaryBorderColor: '#7c7cff',
              lineColor: '#7c7cff',
              background: '#1a1a1a',
              mainBkg: '#2a2a2a',
              nodeBorder: '#7c7cff',
              clusterBkg: '#2a2a2a',
              titleColor: '#f0f0f0',
              textColor: '#f0f0f0',
            },
            fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
          });
          document.addEventListener('DOMContentLoaded', function() {
            setTimeout(function() { window.webkit.messageHandlers.mermaidDone.postMessage('ok'); }, 1500);
          });
          window.onerror = function(msg, url, line) {
            window.webkit.messageHandlers.mermaidError.postMessage(msg);
          };
        </script>
        </body>
        </html>
        """
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mermaidDone")
        config.userContentController.add(context.coordinator, name: "mermaidError")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1.0)
        webView.loadHTMLString(makeHTML(), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: MermaidWebView

        init(parent: MermaidWebView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "mermaidDone" {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isLoading = false
                }
            } else if message.name == "mermaidError" {
                let msg = message.body as? String ?? "Unknown error"
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onError("Web renderer error: \(msg)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.parent.isLoading == true {
                    self?.parent.isLoading = false
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onError("Failed to load mermaid.js: \(error.localizedDescription)")
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onError("Failed to load mermaid.js: \(error.localizedDescription)")
            }
        }
    }
}
#endif

// MARK: - Zoomable Diagram

private struct ZoomableDiagram: View {
    let image: PlatformImage

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 0.5
    private let maxScale: CGFloat = 8.0

    var body: some View {
        GeometryReader { _ in
            platformImageView(for: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3)) {
                        scale = 1.0
                        offset = .zero
                        lastScale = 1.0
                        lastOffset = .zero
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let newScale = lastScale * value
                            scale = min(max(newScale, minScale), maxScale)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if scale != 1.0 || offset != .zero {
                        Text("\(Int(scale * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.surface.opacity(0.9), in: Capsule())
                            .padding(8)
                    }
                }
        }
    }
}

// MARK: - Error Card

private struct ErrorCard: View {
    let error: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Diagram render failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Text(error)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .overlay(Theme.border.opacity(0.5))

            Text(source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(8)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Theme

private let nativeTheme = DiagramTheme(
    background: bmColor(hex: "1a1a1a"),
    foreground: bmColor(hex: "f0f0f0"),
    line: bmColor(hex: "7c7cff"),
    accent: bmColor(hex: "7c7cff"),
    muted: bmColor(hex: "666666"),
    surface: bmColor(hex: "2a2a2a"),
    border: bmColor(hex: "3a3a3a")
)

// MARK: - Helpers

private func platformImageView(for image: PlatformImage) -> Image {
    #if os(macOS)
    Image(nsImage: image)
    #else
    Image(uiImage: image)
    #endif
}

private func bmColor(hex: String) -> BMColor {
    let sanitized = hex.replacingOccurrences(of: "#", with: "")
    var rgb: UInt64 = 0
    Scanner(string: sanitized).scanHexInt64(&rgb)
    return BMColor(
        red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
        green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
        blue: CGFloat(rgb & 0x0000FF) / 255.0,
        alpha: 1.0
    )
}
