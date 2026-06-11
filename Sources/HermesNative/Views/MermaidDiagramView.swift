import SwiftUI
import BeautifulMermaid
import WebKit
import os
#if canImport(UIKit)
import UIKit
#endif

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
    "c4Dynamic", "packet", "kanban", "architecture-beta", "architecture",
]

struct MermaidDiagramView: View {
    let mermaidCode: String
    let isStreaming: Bool

    var body: some View {
        MermaidRendererCoordinator(source: mermaidCode, isStreaming: isStreaming)
    }

    /// Human-readable label for the diagram type declared on the first line
    /// of `source` (fences tolerated). Falls back to "Diagram".
    static func diagramTypeLabel(for source: String) -> String {
        let cleaned = source
            .replacingOccurrences(of: "```mermaid", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = cleaned.split(separator: "\n").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // Longer prefixes first so e.g. "sequenceDiagram" wins over "sequence".
        let labels: [(prefix: String, label: String)] = [
            ("sequencediagram", "Sequence Diagram"),
            ("sequence", "Sequence Diagram"),
            ("statediagram", "State Diagram"),
            ("classdiagram", "Class Diagram"),
            ("erdiagram", "ER Diagram"),
            ("flowchart", "Flowchart"),
            ("graph", "Flowchart"),
            ("mindmap", "Mind Map"),
            ("quadrantchart", "Quadrant Chart"),
            ("gantt", "Gantt Chart"),
            ("pie", "Pie Chart"),
            ("timeline", "Timeline"),
            ("gitgraph", "Git Graph"),
            ("sankey", "Sankey Diagram"),
            ("journey", "User Journey"),
            ("xychart", "XY Chart"),
            ("radar", "Radar Chart"),
            ("treemap", "Treemap"),
            ("block", "Block Diagram"),
            ("packet", "Packet Diagram"),
            ("kanban", "Kanban Board"),
            ("architecture", "Architecture Diagram"),
            ("c4", "C4 Diagram"),
            ("requirementdiagram", "Requirement Diagram"),
        ]
        for (prefix, label) in labels where firstLine.hasPrefix(prefix) {
            return label
        }
        return "Diagram"
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
            return "done-\(cleanedSource.hashValue)"
        }
        // Streaming — stable identity on first line (diagram type)
        let firstLine = cleanedSource.split(separator: "\n").first ?? "diagram"
        return "streaming-\(firstLine)"
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
                    HermesProgressView()
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

        #if os(macOS)
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

        return NSImage(cgImage: cgImage, size: bounds.size)
        #else
        // iOS: BeautifulMermaid's LabelRenderer draws text via UIKit string
        // drawing (`NSAttributedString.draw(in:)`), which renders into the
        // *current UIKit graphics context* — not into the CGContext passed to
        // DiagramRenderer.render. With a raw CGContext (and no
        // UIGraphicsPushContext), text silently draws nowhere, leaving empty
        // boxes. UIGraphicsImageRenderer fixes both requirements at once: it
        // installs its context as the current UIKit context, and that context
        // is already UIKit-flipped (top-left origin) — the same effective
        // coordinate space the manual translate/flip produces on macOS — so no
        // additional y-flip is needed (matching the package's own
        // MermaidImageRenderer iOS path).
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            ctx.setFillColor(nativeTheme.background.cgColor)
            ctx.fill(bounds)
            DiagramRenderer(theme: nativeTheme).render(positioned, in: ctx, bounds: bounds)
        }
        #endif
    }
}

// MARK: - Web (WKWebView) Fallback Renderer

nonisolated(unsafe) private var mermaidImageCache: [String: PlatformImage] = [:]
private let mermaidCacheLock = NSLock()

/// JS expression polled after `didFinish`. Returns "pending" until mermaid.run
/// settles, "error" on render failure, or "x,y,w,h" of the rendered content.
private let mermaidStatusJS = """
window.__mermaidDone === true \
? (window.__mermaidError === true \
? 'error' \
: [window.__mermaidRect.x, window.__mermaidRect.y, window.__mermaidRect.w, window.__mermaidRect.h].join(',')) \
: 'pending'
"""

private let mermaidPollInterval: TimeInterval = 0.125
private let mermaidMaxPollAttempts = 40  // ~5s total

#if os(macOS)
private final class MermaidSharedRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidSharedRenderer()
    @available(macOS, deprecated: 12.0)
    @MainActor private static let processPool = WKProcessPool()
    private let webView: WKWebView
    private let window: NSWindow
    private var pendingCompletion: ((PlatformImage?) -> Void)?
    private var currentNavigation: WKNavigation?
    private var isBusy = false
    private var activeRenderCount = 0
    private let maxActiveRenders = 2
    private var queue: [(String, (PlatformImage?) -> Void)] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        // Disable features that trigger sandbox errors
        config.preferences.isTextInteractionEnabled = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        // Place off-screen in a hidden window so it can render
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1600, height: 1200),
                          styleMask: .borderless, backing: .buffered, defer: true)
        super.init()
        webView.navigationDelegate = self
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        // Pre-warm with a blank page to spin up the WebContent process once
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    func render(source: String, completion: @escaping (PlatformImage?) -> Void) {
        if activeRenderCount >= maxActiveRenders {
            queue.append((source, completion))
            return
        }
        if isBusy {
            queue.append((source, completion))
            return
        }
        activeRenderCount += 1
        isBusy = true
        pendingCompletion = completion
        webView.frame = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        currentNavigation = webView.loadHTMLString(makeMermaidHTML(source: source), baseURL: nil)
    }

    private func processQueue() {
        isBusy = false
        guard !queue.isEmpty else { return }
        let (source, completion) = queue.removeFirst()
        render(source: source, completion: completion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Ignore the pre-warm (and any stale) navigation.
        guard pendingCompletion != nil, navigation === currentNavigation else { return }
        pollForCompletion(attempt: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard pendingCompletion != nil, navigation === currentNavigation else { return }
        finish(with: nil)
    }

    private func pollForCompletion(attempt: Int) {
        webView.evaluateJavaScript(mermaidStatusJS) { [weak self] result, _ in
            guard let self else { return }
            let status = result as? String ?? "pending"
            if status == "pending" {
                guard attempt < mermaidMaxPollAttempts else {
                    log.warning("Mermaid render timed out waiting for completion marker")
                    self.finish(with: nil)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + mermaidPollInterval) { [weak self] in
                    self?.pollForCompletion(attempt: attempt + 1)
                }
                return
            }
            let parts = status.split(separator: ",").compactMap { Double($0) }
            guard status != "error", parts.count == 4, parts[2] > 1, parts[3] > 1 else {
                self.finish(with: nil)
                return
            }
            self.snapshotContent(rect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
        }
    }

    private func snapshotContent(rect: CGRect) {
        let padding: CGFloat = 8
        let target = CGRect(
            x: max(0, rect.minX - padding),
            y: max(0, rect.minY - padding),
            width: rect.width + padding * 2,
            height: rect.height + padding * 2
        )
        // The webview (and host window) must cover the snapshot rect,
        // otherwise large diagrams get clipped at the old frame edge.
        let viewSize = NSSize(width: max(target.maxX, 64), height: max(target.maxY, 64))
        window.setContentSize(viewSize)
        webView.frame = NSRect(origin: .zero, size: viewSize)
        // Give WebKit one paint pass at the new size before snapshotting,
        // or newly exposed regions come back blank.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let config = WKSnapshotConfiguration()
            config.rect = target
            // 2x the content width (in points) for retina-quality zooming.
            config.snapshotWidth = NSNumber(value: Double(target.width) * 2)
            self.webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let self else { return }
                if let error {
                    log.warning("Mermaid snapshot failed: \(error.localizedDescription)")
                }
                self.finish(with: image)
            }
        }
    }

    private func finish(with image: PlatformImage?) {
        pendingCompletion?(image)
        pendingCompletion = nil
        activeRenderCount -= 1
        processQueue()
    }
}
#else
private final class MermaidSharedRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidSharedRenderer()
    @MainActor private static let processPool = WKProcessPool()
    private let webView: WKWebView
    /// Hidden host window: WKWebView on iOS suspends rendering when it is not
    /// attached to any window, so `takeSnapshot` returns blank/partial images.
    /// The window sits below the app's main window (which fully covers it) and
    /// never becomes key, so it is invisible and steals no input.
    private let window: UIWindow
    private var pendingCompletion: ((PlatformImage?) -> Void)?
    private var currentNavigation: WKNavigation?
    private var isBusy = false
    private var activeRenderCount = 0
    private let maxActiveRenders = 2
    private var queue: [(String, (PlatformImage?) -> Void)] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1.0)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        super.init()
        webView.navigationDelegate = self
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        let host = UIViewController()
        host.view.backgroundColor = .clear
        window.rootViewController = host
        host.view.addSubview(webView)
        // isHidden flips to false in attachToSceneIfNeeded() once a
        // UIWindowScene is available (scene-based apps require windows to be
        // parented to a scene before they participate in rendering).
    }

    /// Adopt a connected UIWindowScene (required on iOS 13+ for the window —
    /// and therefore the webview — to be composited). Done lazily at render
    /// time because no scene exists yet when the singleton is first created.
    @MainActor private func attachToSceneIfNeeded() {
        guard window.windowScene == nil else { return }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return }
        window.windowScene = scene
        window.isHidden = false  // visible to the compositor; covered by the app window
    }

    func render(source: String, completion: @escaping (PlatformImage?) -> Void) {
        attachToSceneIfNeeded()
        if activeRenderCount >= maxActiveRenders {
            queue.append((source, completion))
            return
        }
        if isBusy {
            queue.append((source, completion))
            return
        }
        activeRenderCount += 1
        isBusy = true
        pendingCompletion = completion
        webView.frame = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        currentNavigation = webView.loadHTMLString(makeMermaidHTML(source: source), baseURL: nil)
    }

    private func processQueue() {
        isBusy = false
        guard !queue.isEmpty else { return }
        let (source, completion) = queue.removeFirst()
        render(source: source, completion: completion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard pendingCompletion != nil, navigation === currentNavigation else { return }
        pollForCompletion(attempt: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard pendingCompletion != nil, navigation === currentNavigation else { return }
        finish(with: nil)
    }

    private func pollForCompletion(attempt: Int) {
        webView.evaluateJavaScript(mermaidStatusJS) { [weak self] result, _ in
            guard let self else { return }
            let status = result as? String ?? "pending"
            if status == "pending" {
                guard attempt < mermaidMaxPollAttempts else {
                    log.warning("Mermaid render timed out waiting for completion marker")
                    self.finish(with: nil)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + mermaidPollInterval) { [weak self] in
                    self?.pollForCompletion(attempt: attempt + 1)
                }
                return
            }
            let parts = status.split(separator: ",").compactMap { Double($0) }
            guard status != "error", parts.count == 4, parts[2] > 1, parts[3] > 1 else {
                self.finish(with: nil)
                return
            }
            self.snapshotContent(rect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
        }
    }

    private func snapshotContent(rect: CGRect) {
        let padding: CGFloat = 8
        let target = CGRect(
            x: max(0, rect.minX - padding),
            y: max(0, rect.minY - padding),
            width: rect.width + padding * 2,
            height: rect.height + padding * 2
        )
        // The webview (and host window) must cover the snapshot rect,
        // otherwise large diagrams get clipped at the old frame edge.
        let viewFrame = CGRect(x: 0, y: 0,
                               width: max(target.maxX, 64),
                               height: max(target.maxY, 64))
        window.frame = viewFrame
        webView.frame = viewFrame
        // Give WebKit one paint pass at the new size before snapshotting,
        // or newly exposed regions come back blank.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let config = WKSnapshotConfiguration()
            config.rect = target
            // 2x the content width (in points) for retina-quality zooming.
            config.snapshotWidth = NSNumber(value: Double(target.width) * 2)
            self.webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let self else { return }
                if let error {
                    log.warning("Mermaid snapshot failed: \(error.localizedDescription)")
                }
                self.finish(with: image)
            }
        }
    }

    private func finish(with image: PlatformImage?) {
        pendingCompletion?(image)
        pendingCompletion = nil
        activeRenderCount -= 1
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
                    HermesProgressView()
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

    // overflow: visible + inline-block container so the SVG defines the
    // content size; native code measures it and snapshots exactly that rect.
    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      html, body { background: #1a1a1a; overflow: visible; }
      .mermaid-container { display: inline-block; padding: 16px; }
      .mermaid { display: inline-block; }
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
        startOnLoad: false,
        theme: 'dark',
        fontSize: 16,
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
        flowchart: { useMaxWidth: false },
        sequence: { useMaxWidth: false },
        mindmap: { useMaxWidth: false },
        quadrantChart: {
          chartWidth: 700,
          chartHeight: 700,
          pointLabelFontSize: 14,
          quadrantLabelFontSize: 18,
        },
      });
      window.__mermaidDone = false;
      window.__mermaidError = false;
      window.__mermaidRect = { x: 0, y: 0, w: 0, h: 0 };
      mermaid.run({ nodes: [document.getElementById('diagram')] })
        .then(function () {
          var svg = document.querySelector('#diagram svg');
          if (!svg) {
            window.__mermaidError = true;
          } else {
            var r = svg.getBoundingClientRect();
            window.__mermaidRect = {
              x: r.x + window.scrollX,
              y: r.y + window.scrollY,
              w: r.width,
              h: r.height,
            };
          }
          window.__mermaidDone = true;
        })
        .catch(function () {
          window.__mermaidError = true;
          window.__mermaidDone = true;
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
        // Sized by the image's own aspect ratio so the fitted diagram defines
        // the view height (no fixed letterbox band around wide diagrams).
        platformImageView(for: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(image.size, contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
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
