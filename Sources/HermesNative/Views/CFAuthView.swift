import SwiftUI
import WebKit

/// Safari-style sheet for CF Access email OTP authentication.
/// Opens the gateway URL in a WKWebView, lets the user complete
/// the Cloudflare Access login flow, and captures the CF_Authorization cookie.
struct CFAuthView: View {
    let gatewayHost: String
    let onCookie: (HTTPCookie) -> Void
    let onDismiss: () -> Void

    @StateObject private var viewModel: CFAuthViewModel

    init(gatewayHost: String, onCookie: @escaping (HTTPCookie) -> Void, onDismiss: @escaping () -> Void) {
        self.gatewayHost = gatewayHost
        self.onCookie = onCookie
        self.onDismiss = onDismiss
        self._viewModel = StateObject(wrappedValue: CFAuthViewModel(gatewayHost: gatewayHost))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Sign in to Cloudflare Access")
                    .font(.headline)

                Spacer()

                // Balance the cancel button
                Text("Cancel").opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // WebView
            CFWebViewRepresentable(viewModel: viewModel)
                #if os(iOS)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if viewModel.isLoading {
                        ProgressView("Loading…")
                    } else if let error = viewModel.errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button("Retry") {
                                viewModel.errorMessage = nil
                                viewModel.isLoading = true
                                if let url = URL(string: "https://\(viewModel.gatewayHost)/") {
                                    viewModel.webView?.load(URLRequest(url: url))
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #else
        .presentationDetents([.large])
        #endif
        .onReceive(viewModel.$cfAuthCookie) { cookie in
            if let cookie {
                onCookie(cookie)
            }
        }
    }
}

/// ViewModel managing the WKWebView and cookie observation.
@MainActor
final class CFAuthViewModel: ObservableObject {
    let gatewayHost: String
    @Published var cfAuthCookie: HTTPCookie?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private(set) var webView: WKWebView?
    private var navigationDelegate: WebViewNavigationDelegate?
    private var cookieObserver: NSObjectProtocol?
    private(set) var timeoutTask: Task<Void, Never>?

    init(gatewayHost: String) {
        self.gatewayHost = gatewayHost
    }

    func attachWebView(_ webView: WKWebView) {
        self.webView = webView

        // Observe cookie store for CF_Authorization
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("WKHTTPCookieStoreChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForCFAuthCookie(in: cookieStore)
            }
        }

        // Also poll cookies after page loads
        let navDelegate = WebViewNavigationDelegate(viewModel: self)
        self.navigationDelegate = navDelegate
        webView.navigationDelegate = navDelegate

        // Load the gateway root — CF Access will intercept and show login
        guard let url = URL(string: "https://\(gatewayHost)/") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        webView.load(request)

        // Timeout fallback — if nothing happens in 20s, show error
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if isLoading {
                isLoading = false
                errorMessage = "Connection timed out — check that the gateway is reachable and uses HTTPS"
            }
        }
    }

    func checkForCFAuthCookie() async {
        guard let webView else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        await checkForCFAuthCookie(in: cookieStore)
    }

    private func checkForCFAuthCookie(in cookieStore: WKHTTPCookieStore) async {
        let cookies = await cookieStore.allCookies()
        if let cfCookie = cookies.first(where: { $0.name == "CF_Authorization" }) {
            self.cfAuthCookie = cfCookie
        }
    }

    func detachWebView() {
        timeoutTask?.cancel()
        webView = nil
        if let observer = cookieObserver {
            NotificationCenter.default.removeObserver(observer)
            cookieObserver = nil
        }
    }
}

/// WKWebView navigation delegate — checks for CF_Authorization cookie after each page load.
final class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    let viewModel: CFAuthViewModel

    init(viewModel: CFAuthViewModel) {
        self.viewModel = viewModel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        viewModel.isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        viewModel.isLoading = false
        viewModel.timeoutTask?.cancel()
        Task { @MainActor in
            await viewModel.checkForCFAuthCookie()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        viewModel.isLoading = false
        viewModel.timeoutTask?.cancel()
        viewModel.errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        viewModel.isLoading = false
        viewModel.timeoutTask?.cancel()
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                viewModel.errorMessage = "No internet connection"
            case .timedOut:
                viewModel.errorMessage = "Connection timed out"
            case .secureConnectionFailed:
                viewModel.errorMessage = "Secure connection failed — check the gateway URL uses HTTPS"
            case .cannotConnectToHost:
                viewModel.errorMessage = "Cannot connect to host"
            case .appTransportSecurityRequiresSecureConnection:
                viewModel.errorMessage = "HTTP not allowed — gateway must use HTTPS"
            default:
                viewModel.errorMessage = urlError.localizedDescription
            }
        } else {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

/// Cross-platform WKWebView representable for CF Access authentication.
struct CFWebViewRepresentable: View {
    @ObservedObject var viewModel: CFAuthViewModel

    var body: some View {
        #if os(macOS)
        CFWebViewNSView(viewModel: viewModel)
        #else
        CFWebViewUIView(viewModel: viewModel)
        #endif
    }
}

#if os(macOS)
struct CFWebViewNSView: NSViewRepresentable {
    @ObservedObject var viewModel: CFAuthViewModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // Use default store so cookies persist
        let webView = WKWebView(frame: .zero, configuration: config)
        viewModel.attachWebView(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // Cleanup handled in viewModel.detachWebView
    }
}
#else
struct CFWebViewUIView: UIViewRepresentable {
    @ObservedObject var viewModel: CFAuthViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewModel.attachWebView(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        // Cleanup handled in viewModel.detachWebView
    }
}
#endif
