import SwiftUI
import BeautifulMermaid
import WebKit
import os

private let log = Logger(
    subsystem: "com.researchoors.HermesNative",
    category: "MermaidDiagramView"
)

/// BeautifulMermaid native renderer supports exactly 6 diagram types:
/// flowchart, stateDiagram, sequenceDiagram, classDiagram, erDiagram, xyChart.
/// Aliases (graph, sequence, class, er) are NOT natively supported and
/// should fall through to the WKWebView-based mermaid.js renderer.
private let nativeDiagramTypes: Set<String> = [
    "flowchart",
    "sequenceDiagram",
    "stateDiagram",
    "classDiagram",
    "erDiagram",
    "xychart", "xychart-beta", "xyChart",
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
    let isStreaming: Bool

    var body: some View {
        MermaidRendererCoordinator(source: mermaidCode, isStreaming: isStreaming)
    }
}

// MARK: - Coordinator

private struct MermaidRendererCoordinator: View {
    let source: String
    let isStreaming: Bool
    @State private var useFallback = false

    private var cleanedSource: String {
        var s = source
            .replacingOccurrences(of: "```mermaid", with: "")
            .replacingOccurrences(of: "```flowchart", with: "")
            .replacingOccurrences(of: "```sequenceDiagram", with: "")
            .replacingOccurrences(of: "```stateDiagram", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Mermaid mindmap treats `() [] {}` as node shape markers
        // and has no escaping mechanism. Strip them from node text
        // so diagrams with parenthetical content don't fail to parse.
        if s.lowercased().hasPrefix("mindmap") {
            let shapeDelimiters = CharacterSet(charactersIn: "()[]{}")
            s = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    // Don't strip from the root node definition line,
                    // which legitimately uses `(( ... ))` for circle shape.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("root((") || trimmed.hasPrefix("root)") {
                        return String(line)
                    }
                    return String(line.unicodeScalars.filter { !shapeDelimiters.contains($0) })
                }
                .joined(separator: "\n")
        }

        return s
    }

    /// Stable identity key that prevents SwiftUI from destroying/recreating
    /// the WKWebView on every token during streaming.  When the source appears
    /// to still be streaming (no closing fence, or isStreaming flag set), we
    /// key on the diagram type line only.  Once complete we key on the full
    /// content hash so the final render reflects the settled source.
    private var stabilityKey: String {
        let trimmed = cleanedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksComplete = trimmed.hasSuffix("```") || !isStreaming

        if looksComplete {
            return "done-\\(cleanedSource.hashValue)"
        }
        // Streaming — stable identity on first line (diagram type)
        let firstLine = cleanedSource.split(separator: "\n").first ?? "diagram"
        return "streaming-\\(firstLine)"
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
        Group {
            if useFallback || !isNativeSupported {
                WebMermaidRenderer(source: cleanedSource)
            } else {
                NativeMermaidRenderer(source: cleanedSource) {
                    useFallback = true
                }
            }
        }
        .id(stabilityKey)
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

nonisolated(unsafe) private var mermaidImageCache: [String: PlatformImage] = [:]
private let mermaidCacheLock = NSLock()

#if os(macOS)
private final class MermaidSharedRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidSharedRenderer()
    @MainActor private static let processPool = WKProcessPool()
    private let webView: WKWebView
    private var pendingCompletion: ((PlatformImage?) -> Void)?
    private var isBusy = false
    private var queue: [(String, (PlatformImage?) -> Void)] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.navigationDelegate = self
        // Place off-screen in a hidden window so it can render
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800),
                             styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    }

    func render(source: String, completion: @escaping (PlatformImage?) -> Void) {
        if isBusy {
            queue.append((source, completion))
            return
        }
        isBusy = true
        pendingCompletion = completion
        webView.loadHTMLString(makeMermaidHTML(source: source), baseURL: nil)
    }

    private func processQueue() {
        isBusy = false
        guard !queue.isEmpty else { return }
        let (source, completion) = queue.removeFirst()
        render(source: source, completion: completion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let config = WKSnapshotConfiguration()
            self.webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let self else { return }
                if let error {
                    log.warning("Mermaid snapshot failed: \(error.localizedDescription)")
                }
                self.pendingCompletion?(image)
                self.pendingCompletion = nil
                self.processQueue()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingCompletion?(nil)
        pendingCompletion = nil
        processQueue()
    }
}
#else
private final class MermaidSharedRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidSharedRenderer()
    @MainActor private static let processPool = WKProcessPool()
    private let webView: WKWebView
    private var pendingCompletion: ((PlatformImage?) -> Void)?
    private var isBusy = false
    private var queue: [(String, (PlatformImage?) -> Void)] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1.0)
        super.init()
        webView.navigationDelegate = self
    }

    func render(source: String, completion: @escaping (PlatformImage?) -> Void) {
        if isBusy {
            queue.append((source, completion))
            return
        }
        isBusy = true
        pendingCompletion = completion
        webView.loadHTMLString(makeMermaidHTML(source: source), baseURL: nil)
    }

    private func processQueue() {
        isBusy = false
        guard !queue.isEmpty else { return }
        let (source, completion) = queue.removeFirst()
        render(source: source, completion: completion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let config = WKSnapshotConfiguration()
            self.webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let self else { return }
                if let error {
                    log.warning("Mermaid snapshot failed: \(error.localizedDescription)")
                }
                self.pendingCompletion?(image)
                self.pendingCompletion = nil
                self.processQueue()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingCompletion?(nil)
        pendingCompletion = nil
        processQueue()
    }
}
#endif

private struct WebMermaidRenderer: View {
    let source: String
    @State private var cachedImage: PlatformImage?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var renderKey: String
    @State private var renderTask: Task<Void, Never>?

    init(source: String) {
        self.source = source
        _renderKey = State(initialValue: source)
    }

    var body: some View {
        Group {
            if let error = errorMessage {
                ErrorCard(error: error, source: source)
            } else if let image = cachedImage {
                ZoomableDiagram(image: image)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Rendering diagram…")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
                .onAppear { scheduleRender() }
                .onDisappear { renderTask?.cancel() }
            }
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            loadCachedOrRender()
        }
    }

    private func loadCachedOrRender() {
        mermaidCacheLock.lock()
        let cached = mermaidImageCache[renderKey]
        mermaidCacheLock.unlock()
        if let cached {
            cachedImage = cached
            isLoading = false
            return
        }
        MermaidSharedRenderer.shared.render(source: source) { image in
            if let image {
                mermaidCacheLock.lock()
                mermaidImageCache[renderKey] = image
                mermaidCacheLock.unlock()
                cachedImage = image
                isLoading = false
            } else {
                errorMessage = "Failed to render diagram"
            }
        }
    }
}

private func makeMermaidHTML(source: String) -> String {
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
      html, body { background: #1a1a1a; width: 100%; height: 100%; overflow: hidden; }
      .mermaid-container { display: flex; justify-content: center; padding: 16px; }
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
    </script>
    </body>
    </html>
    """
}

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
