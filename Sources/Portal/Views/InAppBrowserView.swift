import SwiftUI
import WebKit

// MARK: - In-App Browser

/// A lightweight in-app web browser: a `WKWebView` wrapped in a titled sheet
/// with a progress bar, back/forward/reload controls, and an "open in the
/// system browser" escape hatch. Used to open feed/digest article links inside
/// the app instead of bouncing the user out to Safari.
///
/// Present it from a `.sheet(item:)` bound to an `InAppBrowserLink`.
///
/// The page can be viewed three ways, toggled from the chrome and remembered
/// per-presentation:
/// - `.docked` — the plain full-bleed sheet layout (default).
/// - `.fullscreen` — an edge-to-edge takeover.
/// - `.canvas` — a draggable, resizable floating window over a dotted canvas
///   backdrop, so the page can be shrunk, moved, and grown freely.
///
/// The single `WKWebView` is reparented between modes (owned by the model), so
/// switching never reloads the page.
internal struct InAppBrowserView: View {
    internal let link: InAppBrowserLink
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = InAppBrowserModel()
    @State private var mode: Mode = .docked

    internal enum Mode {
        case docked, fullscreen, canvas
    }

    internal var body: some View {
        content
            .onAppear { model.load(link.url) }
            .onDisappear { model.detach() }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .canvas:
            canvasContent
        case .docked, .fullscreen:
            dockedContent
        }
    }

    @ViewBuilder
    private var dockedContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            toolbar
            Divider()
            webBody
        }
        // Fullscreen grows the sheet toward the screen; docked keeps a sensible
        // working size. minWidth/Height stops the sheet collapsing below usable.
        .frame(
            minWidth: mode == .fullscreen ? 1200 : 640,
            minHeight: mode == .fullscreen ? 800 : 480
        )
        #else
        NavigationStack {
            webBody
                .navigationTitle(model.pageTitle ?? link.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { iosToolbar }
        }
        #endif
    }

    /// Canvas mode: the page rides in a draggable / resizable card floating over
    /// a dotted backdrop — "grow, shrink, move it anywhere" — with the same
    /// chrome pinned to the card's title bar.
    private var canvasContent: some View {
        FloatingBrowserCanvas {
            VStack(spacing: 0) {
                canvasCardHeader
                Divider().overlay(Theme.border)
                webBody
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        }
    }

    #if !os(macOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isLoading)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { toggle(.canvas) } label: {
                Image(systemName: mode == .canvas ? "arrow.down.right.and.arrow.up.left" : "square.on.square")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button { openExternally() } label: { Label("Open in Safari", systemImage: "safari") }
        }
    }
    #endif

    // MARK: - Shared web body (progress bar + content)

    private var webBody: some View {
        ZStack(alignment: .top) {
            InAppWebViewRepresentable(model: model)

            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }

            if let error = model.errorMessage {
                errorState(error)
            }
        }
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Couldn’t load the page")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("Try Again") { model.reload() }
                    .buttonStyle(.borderedProminent)
                Button("Open in Browser") { openExternally() }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Chrome

    /// Nav buttons + page title + mode controls, shared between the macOS docked
    /// toolbar and the canvas-card title bar.
    private var navChrome: some View {
        HStack(spacing: 12) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(!model.canGoForward)
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(model.isLoading)

            Text(model.pageTitle ?? link.title ?? link.url.absoluteString)
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(Theme.primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { openExternally() } label: { Image(systemName: "safari") }
                .buttonStyle(.plain)
                .help("Open in the system browser")

            Button { toggle(.canvas) } label: {
                Image(systemName: mode == .canvas ? "arrow.down.right.and.arrow.up.left" : "square.on.square")
            }
            .buttonStyle(.plain)
            .help(mode == .canvas ? "Dock" : "Float on a canvas")

            Button { toggle(.fullscreen) } label: {
                Image(systemName: mode == .fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help(mode == .fullscreen ? "Restore" : "Fullscreen")

            Button("Done") { dismiss() }
        }
    }

    #if os(macOS)
    private var toolbar: some View {
        navChrome
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
    #endif

    private var canvasCardHeader: some View {
        navChrome
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceHover.opacity(0.5))
    }

    /// Toggle a mode on/off — tapping the active mode's control returns to
    /// `.docked`, so every button is its own inverse.
    private func toggle(_ target: Mode) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            mode = (mode == target) ? .docked : target
        }
    }

    private func openExternally() {
        #if os(macOS)
        NSWorkspace.shared.open(link.url)
        #else
        UIApplication.shared.open(link.url)
        #endif
        dismiss()
    }
}

// MARK: - Link Model

/// Identifiable wrapper for a URL to open in the in-app browser, suitable for
/// `.sheet(item:)`. Carries an optional title used until the page reports its
/// own `<title>`.
internal struct InAppBrowserLink: Identifiable {
    internal let id = UUID()
    internal let url: URL
    internal var title: String?

    /// Build from a raw string; nil when the string isn't a valid URL.
    internal init?(urlString: String, title: String? = nil) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        self.url = url
        self.title = title
    }
}

// MARK: - WebView State

/// Drives the `WKWebView`: owns the instance, tracks load state, and exposes
/// navigation actions to the SwiftUI layer.
@MainActor
internal final class InAppBrowserModel: ObservableObject {
    @Published internal var isLoading = false
    @Published internal var progress = 0.0
    @Published internal var canGoBack = false
    @Published internal var canGoForward = false
    @Published internal var pageTitle: String?
    @Published internal var errorMessage: String?

    internal private(set) var webView: WKWebView?
    private var delegate: InAppBrowserNavigationDelegate?
    private var observers: [NSKeyValueObservation] = []
    private var pendingURL: URL?

    /// The single `WKWebView` for this browser, created on first use. Owning it
    /// on the model (rather than letting each representable make its own in
    /// `makeNSView`) is what lets the page survive switching presentation modes
    /// — docked ⇄ fullscreen ⇄ canvas tile reparent the SAME instance instead
    /// of spinning up a fresh one and reloading.
    internal func makeOrReuseWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Persistent store so any CF-Access / gateway auth cookies established
        // elsewhere in the app carry over — a digest link that routes to the
        // protected server then loads instead of stalling on a login wall.
        config.websiteDataStore = .default()
        let created = WKWebView(frame: .zero, configuration: config)
        #if !os(macOS)
        created.scrollView.isScrollEnabled = true
        created.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        attach(created)
        return created
    }

    private func attach(_ webView: WKWebView) {
        self.webView = webView
        let navDelegate = InAppBrowserNavigationDelegate(model: self)
        self.delegate = navDelegate
        webView.navigationDelegate = navDelegate

        // Track progress + nav availability via KVO so the chrome stays live.
        observers = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    if let title = webView.title, !title.isEmpty { self?.pageTitle = title }
                }
            }
        ]

        if let pendingURL {
            self.pendingURL = nil
            loadNow(pendingURL)
        }
    }

    /// Load a URL. If the web view isn't attached yet (first render), stash it
    /// and load as soon as `attach` runs.
    internal func load(_ url: URL) {
        guard webView != nil else { pendingURL = url; return }
        loadNow(url)
    }

    private func loadNow(_ url: URL) {
        guard let webView else { return }
        errorMessage = nil
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.load(request)
    }

    internal func reload() {
        errorMessage = nil
        if let webView, webView.url != nil {
            webView.reload()
        } else if webView != nil, let pendingURL {
            loadNow(pendingURL)
        }
    }

    internal func goBack() { webView?.goBack() }
    internal func goForward() { webView?.goForward() }

    internal func detach() {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        webView?.navigationDelegate = nil
        webView = nil
        delegate = nil
    }
}

// MARK: - Navigation Delegate

/// Reports load lifecycle back to `InAppBrowserModel` and maps `URLError`s to
/// human-readable messages, mirroring the CF-auth web view's error handling.
internal final class InAppBrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    private weak var model: InAppBrowserModel?

    internal init(model: InAppBrowserModel) {
        self.model = model
    }

    // WKNavigationDelegate hands back an implicitly-unwrapped `WKNavigation!`;
    // the signature must match the protocol, so the IUO is not ours to remove.
    // swiftlint:disable implicitly_unwrapped_optional
    internal func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor [weak model] in
            model?.isLoading = true
            model?.errorMessage = nil
        }
    }

    internal func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak model] in model?.isLoading = false }
    }

    internal func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: error)
    }

    internal func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: error)
    }
    // swiftlint:enable implicitly_unwrapped_optional

    private func finish(with error: Error) {
        // Ignore the "cancelled" that fires when a load is superseded (e.g. a
        // redirect or a second load) — it isn't a user-visible failure.
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        let message = Self.describe(error)
        Task { @MainActor [weak model] in
            model?.isLoading = false
            model?.errorMessage = message
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet: return "No internet connection."
        case .timedOut:               return "The connection timed out."
        case .cannotFindHost:         return "Can’t find that server."
        case .cannotConnectToHost:    return "Can’t connect to that server."
        case .secureConnectionFailed: return "The secure connection failed."
        default:                      return urlError.localizedDescription
        }
    }
}

// MARK: - Floating Canvas

/// Hosts one card floating over a dotted "canvas" backdrop. The card can be
/// dragged anywhere by its body and resized from the bottom-right corner —
/// "grow, shrink, move it around." A single card (the browser) rather than the
/// full multi-panel `DashboardCanvasView`, which is wired to the artifact/graph
/// panel registry; this keeps the browser self-contained while giving the same
/// free-form feel.
private struct FloatingBrowserCanvas<Card: View>: View {
    @ViewBuilder internal let card: Card

    @State private var origin = CGPoint(x: 40, y: 40)
    @State private var size = CGSize(width: 720, height: 520)
    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    private static var minSize: CGSize { CGSize(width: 320, height: 240) }
    private static var handleSize: CGFloat { 20 }

    internal var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DottedCanvasBackdrop()

                card
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .overlay(alignment: .bottomTrailing) { resizeHandle }
                    .offset(x: origin.x, y: origin.y)
                    .gesture(moveGesture(bounds: geo.size))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .onAppear { centerIfNeeded(in: geo.size) }
        }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.tertiary)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 5))
            .padding(6)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
            .help("Drag to resize")
    }

    private func moveGesture(bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? origin
                if dragStart == nil { dragStart = origin }
                origin = CGPoint(
                    x: max(0, min(bounds.width - 60, start.x + value.translation.width)),
                    y: max(0, min(bounds.height - 40, start.y + value.translation.height))
                )
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = resizeStart ?? size
                if resizeStart == nil { resizeStart = size }
                size = CGSize(
                    width: max(Self.minSize.width, start.width + value.translation.width),
                    height: max(Self.minSize.height, start.height + value.translation.height)
                )
            }
            .onEnded { _ in resizeStart = nil }
    }

    private func centerIfNeeded(in bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let w = min(size.width, bounds.width - 40)
        let h = min(size.height, bounds.height - 40)
        size = CGSize(width: w, height: h)
        origin = CGPoint(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2)
    }
}

/// A faint dotted field that reads as a "canvas" surface behind the floating
/// card — matches the dashboard-canvas idiom.
private struct DottedCanvasBackdrop: View {
    internal var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let dot: CGFloat = 1.4
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(Theme.border.opacity(0.5)))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(Theme.background)
        .ignoresSafeArea()
    }
}

// MARK: - Representable

private struct InAppWebViewRepresentable: View {
    @ObservedObject internal var model: InAppBrowserModel

    internal var body: some View {
        #if os(macOS)
        InAppWebViewNSView(model: model)
        #else
        InAppWebViewUIView(model: model)
        #endif
    }
}

// A `WKWebView` can only live in one view hierarchy at a time, so each
// representable REPARENTS the model's single instance into a plain container
// view rather than owning its own. Switching presentation modes therefore
// moves the same web view — and its live page — instead of reloading.
#if os(macOS)
private struct InAppWebViewNSView: NSViewRepresentable {
    @ObservedObject internal var model: InAppBrowserModel

    internal func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = model.makeOrReuseWebView()
        reparent(webView, into: container)
        return container
    }

    internal func updateNSView(_ nsView: NSView, context: Context) {
        let webView = model.makeOrReuseWebView()
        if webView.superview !== nsView {
            reparent(webView, into: nsView)
        }
    }

    private func reparent(_ webView: WKWebView, into container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
#else
private struct InAppWebViewUIView: UIViewRepresentable {
    @ObservedObject internal var model: InAppBrowserModel

    internal func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let webView = model.makeOrReuseWebView()
        reparent(webView, into: container)
        return container
    }

    internal func updateUIView(_ uiView: UIView, context: Context) {
        let webView = model.makeOrReuseWebView()
        if webView.superview !== uiView {
            reparent(webView, into: uiView)
        }
    }

    private func reparent(_ webView: WKWebView, into container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
#endif
