#if os(macOS)
import SwiftUI
import WebKit
import AppKit
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "ArtifactFullscreen")

// MARK: - Shared interactive web configuration

/// Configuration + content resolution shared by the inline artifact renderer
/// (`InlineHTMLNSView`) and the native-fullscreen window below, so both host
/// interactive HTML with identical WebKit settings.
internal enum InteractiveArtifactWeb {
    /// Base WKWebView configuration for interactive artifact content: JavaScript
    /// on, element-fullscreen requests honored, and an ephemeral data store so a
    /// page can't persist anything across sessions. Callers layer their own user
    /// scripts (the intent bridge, the pointer-lock bridge) on top.
    internal static func baseConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = .nonPersistent()
        return config
    }

    /// The raw HTML document to load for an immersive presentation of `kind`,
    /// or nil when the kind isn't web-backed interactive content (so callers can
    /// hide the "Enter Full Screen" affordance). `html` is served verbatim;
    /// `model3d` is rendered through the Three.js template the inline viewer uses.
    internal static func immersiveHTML(kind: String, content: String) -> String? {
        switch kind {
        case "html":
            return content
        case "model3d":
            guard let spec = Model3DTemplate.parse(content) else { return nil }
            return Model3DTemplate.render(spec)
        default:
            return nil
        }
    }

    /// Whether `kind` can be presented in the immersive fullscreen window.
    internal static func supportsImmersiveFullscreen(_ kind: String) -> Bool {
        kind == "html" || kind == "model3d"
    }
}

// MARK: - Fullscreen window

/// Presents a single interactive artifact in a dedicated native-fullscreen
/// `NSWindow`.
///
/// Why a separate window instead of the in-app expanded overlay: WebKit's
/// Pointer Lock (hidden OS cursor + relative mouse deltas — what a first-person
/// / orbit 3D scene needs) and raw keyboard capture are only reliable when the
/// `WKWebView` is the first responder of a real *key* window that owns the
/// screen. A SwiftUI `.overlay` buried in the docked window is neither, so the
/// lock silently fails and the visible cursor floats "on top of" the scene. A
/// standalone key window in native fullscreen is the environment where the lock
/// engages. Escape is left entirely to WebKit (release the lock) and macOS
/// (exit fullscreen once unlocked) — this controller binds no keys of its own,
/// so nothing competes with the lock-release gesture.
@MainActor
internal final class ArtifactFullscreenWindowController: NSObject, NSWindowDelegate {
    // no_new_singletons exempt in .swiftlint.yml (window-hosting controllers,
    // like HTMLPreviewPresenter, are app-lifetime singletons by nature).
    internal static let shared = ArtifactFullscreenWindowController()

    private var window: NSWindow?
    private var webView: InputCapturingWebView?

    override private init() { super.init() }

    /// Whether an artifact is currently presented fullscreen.
    internal var isPresenting: Bool { window != nil }

    /// Build a fresh interactive web view, load `html`, and take it to native
    /// fullscreen. Any prior presentation is torn down first so a previous
    /// WebGL/animation loop can't keep running behind the new one.
    internal func present(html: String, title: String) {
        close()

        let config = InteractiveArtifactWeb.baseConfiguration()
        // The trusted-gesture pointer-lock helper: a real click on a <canvas>
        // requests the lock from that same event. See HTMLPointerLockBridge.
        config.userContentController.addUserScript(WKUserScript(
            source: HTMLPointerLockBridge.userScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: WKContentWorld.world(name: HTMLPointerLockBridge.contentWorldName)
        ))

        let webView = InputCapturingWebView(frame: .zero, configuration: config)
        webView.capturesInput = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = true
        self.webView = webView

        // Letterbox the scene on black so a non-fullscreen aspect ratio doesn't
        // show the desktop through the transparent web view.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screenFrame.width * 0.8, height: screenFrame.height * 0.8),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = container
        window.delegate = self
        window.initialFirstResponder = webView
        window.center()
        self.window = window

        webView.loadHTMLString(html, baseURL: nil)
        window.makeKeyAndOrderFront(nil)
        // Go fullscreen once ordered front; makeFirstResponder happens on the
        // become-key / enter-fullscreen callbacks so focus lands after the
        // transition, not before the window is real.
        window.toggleFullScreen(nil)
        log.debug("presented artifact fullscreen: \(title, privacy: .public)")
    }

    /// Tear down the current presentation, stopping the page so its render loop
    /// releases. Idempotent.
    internal func close() {
        guard let window else { return }
        // Blank the page first so any WebGL/rAF loop halts before teardown.
        webView?.loadHTMLString("", baseURL: nil)
        webView?.stopLoading()
        window.delegate = nil
        window.orderOut(nil)
        self.window = nil
        self.webView = nil
    }

    private func focusWebView() {
        guard let window, let webView else { return }
        window.makeFirstResponder(webView)
    }

    // MARK: NSWindowDelegate

    internal func windowDidBecomeKey(_ notification: Notification) {
        // Pointer Lock + key events require the web view to be first responder.
        focusWebView()
    }

    internal func windowDidEnterFullScreen(_ notification: Notification) {
        focusWebView()
    }

    internal func windowWillClose(_ notification: Notification) {
        // The user closed the window (Cmd-W / traffic light) rather than going
        // through close() — release our references and stop the page.
        if (notification.object as? NSWindow) === window {
            webView?.loadHTMLString("", baseURL: nil)
            webView?.stopLoading()
            window?.delegate = nil
            window = nil
            webView = nil
        }
    }
}
#endif
