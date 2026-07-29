import SwiftUI
import WebKit

// MARK: - In-App Browser

/// A lightweight in-app web browser: a `WKWebView` wrapped in a titled sheet
/// with a progress bar, back/forward/reload controls, and an "open in the
/// system browser" escape hatch. Used to open feed/digest article links inside
/// the app instead of bouncing the user out to Safari.
///
/// Present it from a `.sheet(item:)` bound to an `InAppBrowserLink`.
internal struct InAppBrowserView: View {
    internal let link: InAppBrowserLink
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = InAppBrowserModel()

    internal var body: some View {
        content
            .onAppear { model.load(link.url) }
            .onDisappear { model.detach() }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            toolbar
            Divider()
            webBody
        }
        .frame(minWidth: 640, minHeight: 480)
        #else
        NavigationStack {
            webBody
                .navigationTitle(model.pageTitle ?? link.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.isLoading)
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            openExternally()
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                    }
                }
        }
        #endif
    }

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

    // MARK: - macOS toolbar

    #if os(macOS)
    private var toolbar: some View {
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
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { openExternally() } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.plain)
            .help("Open in the system browser")

            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    #endif

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

    internal func attach(_ webView: WKWebView) {
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

#if os(macOS)
private struct InAppWebViewNSView: NSViewRepresentable {
    @ObservedObject internal var model: InAppBrowserModel

    internal func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent store so any CF-Access / gateway auth cookies established
        // elsewhere in the app carry over — a digest link that routes to the
        // protected server then loads instead of stalling on a login wall.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        model.attach(webView)
        return webView
    }

    internal func updateNSView(_ nsView: WKWebView, context: Context) {}

    internal static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {}
}
#else
private struct InAppWebViewUIView: UIViewRepresentable {
    @ObservedObject internal var model: InAppBrowserModel

    internal func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        model.attach(webView)
        return webView
    }

    internal func updateUIView(_ uiView: WKWebView, context: Context) {}

    internal static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {}
}
#endif
