import WebKit
import os

#if os(macOS)
import AppKit
internal typealias SnapshotImage = NSImage
#else
import UIKit
internal typealias SnapshotImage = UIImage
#endif

/// Renders a web page offscreen and captures a thumbnail of it — a real
/// "preview of the webpage" for feed cards (as opposed to the article's OG
/// image). Snapshots are cached by URL for the app's lifetime and rendering is
/// serialized to one page at a time, so a long feed doesn't spin up dozens of
/// concurrent web views. Cards request a snapshot lazily (on appear); a cache
/// hit returns instantly.
///
/// This is best-effort chrome — a failed or slow render just leaves the card
/// on its fallback image, never blocks anything.
@MainActor
internal final class WebPageSnapshotService {
    private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "WebPageSnapshot")

    /// URL string → captured snapshot. Also records misses (nil) so a page that
    /// failed to render isn't retried on every scroll.
    private var cache: [String: SnapshotImage] = [:]
    private var failed: Set<String> = []

    /// One in-flight render at a time — the live renderer holds a strong ref to
    /// itself until it finishes, and the queue serializes the rest.
    private var queue: [PendingRender] = []
    private var isRendering = false

    private struct PendingRender {
        internal let url: URL
        internal let completion: (SnapshotImage?) -> Void
    }

    /// Target render size. The page is laid out at this width; the captured
    /// image is downscaled by the card as needed.
    private static let renderSize = CGSize(width: 1000, height: 700)

    internal init() {}

    /// Return a cached snapshot if we have one.
    internal func cached(for url: URL) -> SnapshotImage? {
        cache[url.absoluteString]
    }

    /// True once we've tried and failed — the card should stop asking.
    internal func didFail(for url: URL) -> Bool {
        failed.contains(url.absoluteString)
    }

    /// Request a snapshot. Returns immediately via `completion` on the main
    /// actor: a cache hit calls back synchronously-ish; a miss enqueues a render.
    internal func snapshot(for url: URL, completion: @escaping (SnapshotImage?) -> Void) {
        if let hit = cache[url.absoluteString] {
            completion(hit)
            return
        }
        if failed.contains(url.absoluteString) {
            completion(nil)
            return
        }
        queue.append(PendingRender(url: url, completion: completion))
        pump()
    }

    private func pump() {
        guard !isRendering, !queue.isEmpty else { return }
        isRendering = true
        let job = queue.removeFirst()
        renderNow(job)
    }

    private func renderNow(_ job: PendingRender) {
        let renderer = OffscreenPageRenderer(size: Self.renderSize)
        renderer.render(url: job.url) { [weak self] image in
            guard let self else { return }
            let key = job.url.absoluteString
            if let image {
                self.cache[key] = image
            } else {
                self.failed.insert(key)
                self.log.debug("snapshot render failed for \(key, privacy: .public)")
            }
            job.completion(image)
            self.isRendering = false
            self.pump()
        }
    }
}

/// A throwaway offscreen `WKWebView` that loads one URL, waits for it to settle,
/// and captures a snapshot. It retains itself for the duration of the render via
/// the navigation delegate, then releases when the completion fires.
@MainActor
private final class OffscreenPageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: ((SnapshotImage?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    /// Keeps the renderer alive across the async load without an external owner.
    private var selfHold: OffscreenPageRenderer?

    internal init(size: CGSize) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    internal func render(url: URL, completion: @escaping (SnapshotImage?) -> Void) {
        self.completion = completion
        self.selfHold = self
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        webView.load(request)

        // Hard ceiling — never let a stuck page pin the render queue.
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(25))
            } catch {
                return // cancelled because the render already finished
            }
            guard let self, !Task.isCancelled else { return }
            self.finish(nil)
        }
    }

    // WKNavigationDelegate's generated signatures use implicitly-unwrapped
    // `WKNavigation!` — we don't control them, so scope the rule off here.
    // swiftlint:disable implicitly_unwrapped_optional
    internal func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give the page a beat to paint above-the-fold content before snapping.
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return // cancelled
            }
            guard let self, !Task.isCancelled else { return }
            self.capture()
        }
    }

    internal func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    internal func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
    // swiftlint:enable implicitly_unwrapped_optional

    private func capture() {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: webView.bounds.size)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.finish(image)
        }
    }

    private func finish(_ image: SnapshotImage?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let done = completion
        completion = nil
        webView.navigationDelegate = nil
        done?(image)
        // Release the self-hold last so we survive until the callback returns.
        selfHold = nil
    }
}
