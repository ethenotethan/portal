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
    @MainActor
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

    /// JavaScript surface a page must touch to be navigable while the pointer is
    /// locked. Under Pointer Lock the spec **freezes** `clientX`/`clientY` at
    /// their last pre-lock values and reports motion only as `movementX` /
    /// `movementY`, so a page that never mentions any of these cannot see the
    /// mouse move at all once captured.
    private static let pointerLockAPIs = [
        "movementX", "movementY", "pointerLockElement",
        "requestPointerLock", "exitPointerLock", "PointerLockControls"
    ]

    /// Whether `html` is authored to be driven by a captured pointer.
    ///
    /// A crude source sniff, deliberately: these identifiers are the literal API
    /// a document *must* name to read relative motion, so their total absence is
    /// conclusive — such a page cannot turn its camera under lock no matter what
    /// else it does. False positives are harmless (a lock-aware page gets the
    /// lock it wanted); a false negative just leaves the page with a visible
    /// cursor, which is how it behaved before host capture existed.
    internal static func pageUsesPointerLock(_ html: String) -> Bool {
        pointerLockAPIs.contains { html.contains($0) }
    }

    /// Whether `html` turns its camera by dragging with a button held, and so
    /// needs captured motion translated into a synthetic drag
    /// (`HTMLPointerLockBridge.dragLookShimSource`).
    ///
    /// True only when the page reads absolute cursor coordinates, listens for a
    /// button press, and names no Pointer Lock API at all — the signature of a
    /// world authored before Portal taught the capture contract.
    internal static func pageDragsToLook(_ html: String) -> Bool {
        guard !pageUsesPointerLock(html) else { return false }
        let readsAbsolute = html.contains("clientX") || html.contains("clientY")
        let watchesButton = html.contains("mousedown") || html.contains("pointerdown")
        return readsAbsolute && watchesButton
    }

    /// Whether the host should turn the first canvas click into a Pointer Lock
    /// request (`HTMLPointerLockBridge`).
    ///
    /// Two ways an html page earns capture: it reads relative motion itself, or
    /// it drags on absolute coordinates and the shim translates for it. Kind
    /// alone is not enough, and neither is refusing to capture — a drag world
    /// left uncaptured still makes the user hold a button to turn, which is the
    /// whole complaint. Capturing it *without* the shim is worse still: the spec
    /// freezes `clientX`, so every drag computes a zero delta and the camera
    /// locks up.
    ///
    /// `model3d` is excluded regardless: `Model3DTemplate` drives OrbitControls,
    /// whose zoom and pan legitimately need a real, visible cursor.
    ///
    /// Pages that genuinely want the lock can still call `requestPointerLock()`
    /// themselves; the window grants it either way.
    internal static func autoCapturesPointer(kind: String, content: String) -> Bool {
        guard kind == "html" else { return false }
        return pageUsesPointerLock(content) || pageDragsToLook(content)
    }

    /// Opt-in on-screen Pointer Lock trace, for when the cursor still floats and
    /// the reason is invisible: WebKit's refusals are private and `log.debug`
    /// needs root to surface. Enable with
    /// `defaults write com.ethenotethan.Portal HermesPointerLockTrace -bool YES`.
    internal static var showsPointerLockTrace: Bool {
        UserDefaults.standard.bool(forKey: "HermesPointerLockTrace")
    }
}

// MARK: - Pointer Lock permission

/// Grants WebKit's Pointer Lock requests for the immersive artifact window and
/// tracks whether the lock is currently held.
///
/// **Why this class has to exist, and why it uses private selectors:** a page
/// calling `requestPointerLock()` inside a `WKWebView` is refused unless the
/// web view's `uiDelegate` answers WebKit's pointer-lock callbacks. Those
/// callbacks live in `WKUIDelegatePrivate`, not the public `WKUIDelegate` — as
/// of macOS 26 AppKit exposes no public equivalent. WebKit's `UIDelegate` shim
/// asks `respondsToSelector:` for each and, finding none, completes the request
/// with `false`. Portal set no `uiDelegate` at all, so every lock request was
/// denied and the cursor kept floating over the scene even after the artifact
/// moved into its own fullscreen window.
///
/// The selectors are optional and looked up dynamically by WebKit, so if a
/// future WebKit renames them nothing crashes — the lock simply stops being
/// granted, which is exactly today's behavior. `PointerLockEnabled` is on by
/// default in `WKPreferences`, so no feature flag is involved.
@MainActor
internal final class ArtifactPointerLockDelegate: NSObject, WKUIDelegate {
    /// Selector names WebKit probes on the UI delegate. Kept as constants so a
    /// test can assert this object actually answers them — a silent typo here is
    /// indistinguishable from the bug this class fixes.
    internal static let requestSelectorName = "_webViewDidRequestPointerLock:completionHandler:"
    internal static let didLoseSelectorName = "_webViewDidLosePointerLock:"

    /// Deliberately NOT implemented, and asserted absent by a test.
    ///
    /// WebKit probes for this older shape FIRST and, finding it, never calls the
    /// completion-handler variant above. The legacy shape has no completion
    /// handler — implementing it is meant to *be* the grant — but that path no
    /// longer grants anything in current WebKit: the request is refused, and it
    /// surfaces to the page as `WrongDocumentError: Pointer lock requires the
    /// window to have focus`, which sends you hunting a focus bug that isn't
    /// there. The window was key, main, and active; the document had focus.
    ///
    /// Proven by A/B on one page and one click, changing only this selector's
    /// presence: implemented → `REJECTED WrongDocumentError` every time; hidden
    /// → modern callback fires, `pointerlockchange` reports the canvas, the
    /// promise resolves. Safari's own `BrowserUIDelegate` implements only the
    /// modern selector plus the did-lose notification.
    internal static let shadowingLegacySelectorName = "_webViewRequestPointerLock:"

    /// True while the page holds the pointer. Read by the window controller so
    /// Escape can mean "release the mouse" first and "leave fullscreen" second.
    internal private(set) var isPointerLocked = false

    /// Called when the lock is taken or released, so the host can update chrome.
    internal var onLockChange: ((Bool) -> Void)?

    @objc(_webViewDidRequestPointerLock:completionHandler:)
    internal func webViewDidRequestPointerLock(
        _ webView: WKWebView,
        completionHandler: @escaping (Bool) -> Void
    ) {
        // The request already passed WebKit's own gates (trusted gesture, focused
        // document, visible page) before reaching the delegate, so there is
        // nothing further to validate — the page may capture the cursor.
        setLocked(true)
        completionHandler(true)
    }

    @objc(_webViewDidLosePointerLock:)
    internal func webViewDidLosePointerLock(_ webView: WKWebView) {
        setLocked(false)
    }

    /// Reset for a fresh presentation — a torn-down page can't still hold the
    /// cursor, and a stale `true` would make Escape a no-op.
    internal func reset() {
        setLocked(false)
    }

    private func setLocked(_ locked: Bool) {
        guard isPointerLocked != locked else { return }
        isPointerLocked = locked
        log.debug("pointer lock \(locked ? "acquired" : "released", privacy: .public)")
        onLockChange?(locked)
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
/// engages — together with `ArtifactPointerLockDelegate`, which is what actually
/// permits the lock.
///
/// Escape is handled in two stages by a monitor scoped to this window: while the
/// page holds the pointer the key is passed through untouched so WebKit performs
/// its standard release; once unlocked, Escape leaves fullscreen and closes.
@MainActor
internal final class ArtifactFullscreenWindowController: NSObject, NSWindowDelegate {
    // no_new_singletons exempt in .swiftlint.yml (window-hosting controllers,
    // like HTMLPreviewPresenter, are app-lifetime singletons by nature).
    internal static let shared = ArtifactFullscreenWindowController()

    private var window: NSWindow?
    private var webView: InputCapturingWebView?
    private var hintView: NSView?
    private var escapeMonitor: Any?
    private var hintTimer: Timer?
    private let pointerLock = ArtifactPointerLockDelegate()
    /// Set when Escape / an explicit close arrives while still fullscreen: the
    /// window is torn down only after the fullscreen transition finishes, or the
    /// screen is left with an empty green space.
    private var closeAfterExitingFullScreen = false

    override private init() { super.init() }

    /// Whether an artifact is currently presented fullscreen.
    internal var isPresenting: Bool { window != nil }

    /// Build a fresh interactive web view, load `html`, and take it to native
    /// fullscreen. Any prior presentation is torn down first so a previous
    /// WebGL/animation loop can't keep running behind the new one.
    ///
    /// `autoCapturesPointer` injects the first-click Pointer Lock helper. Pass
    /// false for scenes driven by absolute cursor position (OrbitControls) —
    /// see `InteractiveArtifactWeb.autoCapturesPointer(kind:content:)`.
    ///
    /// A pre-contract drag-to-look world additionally gets the shim that turns
    /// captured motion into the synthetic drag it expects, derived from `html`
    /// here rather than passed in so the two can never disagree.
    internal func present(html: String, title: String, autoCapturesPointer: Bool = true) {
        let dragLookShim = InteractiveArtifactWeb.pageDragsToLook(html)
        close()
        pointerLock.reset()

        let config = InteractiveArtifactWeb.baseConfiguration()
        if autoCapturesPointer {
            // The trusted-gesture pointer-lock helper: a real click on a <canvas>
            // requests the lock from that same event. See HTMLPointerLockBridge.
            config.userContentController.addUserScript(WKUserScript(
                source: HTMLPointerLockBridge.userScriptSource,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: WKContentWorld.world(name: HTMLPointerLockBridge.contentWorldName)
            ))
            if dragLookShim {
                config.userContentController.addUserScript(WKUserScript(
                    source: HTMLPointerLockBridge.dragLookShimSource,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true,
                    in: WKContentWorld.world(name: HTMLPointerLockBridge.contentWorldName)
                ))
            }
            if InteractiveArtifactWeb.showsPointerLockTrace {
                config.userContentController.addUserScript(WKUserScript(
                    source: HTMLPointerLockBridge.captureDiagnosticSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: WKContentWorld.world(name: HTMLPointerLockBridge.contentWorldName)
                ))
            }
        }

        let webView = InputCapturingWebView(frame: .zero, configuration: config)
        webView.capturesInput = true
        // Without a uiDelegate WebKit denies every requestPointerLock() call.
        webView.uiDelegate = pointerLock
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
            // .fullSizeContentView + a hidden, transparent titlebar means the
            // scene is edge-to-edge even during the transition, instead of
            // sitting under a chrome band the user has to look past.
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.contentView = container
        window.delegate = self
        window.initialFirstResponder = webView
        window.center()
        self.window = window

        if autoCapturesPointer {
            installHint(in: container)
        }
        installEscapeMonitor()

        webView.loadHTMLString(html, baseURL: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Pointer Lock is refused unless the document's window has focus, so the
        // window must be key and the web view first responder before the page
        // can capture anything. makeFirstResponder also runs from the
        // become-key / enter-fullscreen callbacks.
        window.makeFirstResponder(webView)
        enterFullScreen(window)
        log.debug("presented artifact fullscreen: \(title, privacy: .public)")
    }

    /// AppKit refuses `toggleFullScreen` when it lands in the same turn of the
    /// run loop as `makeKeyAndOrderFront` — the window is not yet on screen, the
    /// transition is dropped, and the user is left staring at a floating 80%
    /// window instead of a fullscreen scene. Ask on the next turn, then verify
    /// and retry once.
    private func enterFullScreen(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                guard !window.styleMask.contains(.fullScreen) else { return }
                log.error("fullscreen transition did not take — retrying once")
                window.toggleFullScreen(nil)
            }
        }
    }

    /// Escape, scoped to this window only. While the pointer is captured the
    /// event is handed to WebKit untouched (it performs the release); otherwise
    /// it leaves fullscreen and dismisses — the "escape out of full full screen"
    /// path. The monitor is local, so the rest of the app keeps its own Escape.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let escapeKeyCode: UInt16 = 53
            guard event.keyCode == escapeKeyCode, event.window === window else { return event }
            // Let WebKit release the cursor first; the next Escape exits.
            guard !self.pointerLock.isPointerLocked else { return event }
            self.requestClose()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }

    /// A transient "how to drive this" strip. Pointer Lock cannot be taken on
    /// the user's behalf — the spec requires a gesture in *this* document, and
    /// the click that opened the window happened in another one — so the one
    /// click that captures the mouse has to be asked for rather than assumed.
    private func installHint(in container: NSView) {
        let text = NSTextField(labelWithString: "Click the scene to capture your mouse  ·  Esc releases  ·  Esc again exits")
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .white
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(text)
        container.addSubview(backdrop)
        hintView = backdrop

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -10),
            backdrop.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -40)
        ])

        // Hide the moment the mouse is actually captured, so it never overlaps
        // the experience it was explaining.
        pointerLock.onLockChange = { [weak self] locked in
            if locked { self?.fadeOutHint() }
        }
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOutHint() }
        }
    }

    private func fadeOutHint() {
        hintTimer?.invalidate()
        hintTimer = nil
        guard let hintView else { return }
        self.hintView = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            hintView.animator().alphaValue = 0
        } completionHandler: {
            // AppKit completes an animation group on the main thread, but this
            // callback is not actor-annotated. Restore the isolation that the
            // API does not express before touching the NSView.
            MainActor.assumeIsolated { hintView.removeFromSuperview() }
        }
    }

    /// Leave fullscreen first if needed, then tear down. Escape and the traffic
    /// light both come through here.
    internal func requestClose() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            closeAfterExitingFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        close()
    }

    /// Tear down the current presentation, stopping the page so its render loop
    /// releases. Idempotent.
    internal func close() {
        removeEscapeMonitor()
        hintTimer?.invalidate()
        hintTimer = nil
        hintView = nil
        pointerLock.onLockChange = nil
        pointerLock.reset()
        closeAfterExitingFullScreen = false
        guard let window else { return }
        // Blank the page first so any WebGL/rAF loop halts before teardown.
        webView?.loadHTMLString("", baseURL: nil)
        webView?.stopLoading()
        webView?.uiDelegate = nil
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

    internal func windowDidExitFullScreen(_ notification: Notification) {
        if closeAfterExitingFullScreen {
            closeAfterExitingFullScreen = false
            close()
        } else {
            focusWebView()
        }
    }

    internal func windowWillClose(_ notification: Notification) {
        // The user closed the window (Cmd-W / traffic light) rather than going
        // through close() — release our references and stop the page.
        if (notification.object as? NSWindow) === window {
            removeEscapeMonitor()
            hintTimer?.invalidate()
            hintTimer = nil
            hintView = nil
            pointerLock.onLockChange = nil
            pointerLock.reset()
            webView?.loadHTMLString("", baseURL: nil)
            webView?.stopLoading()
            webView?.uiDelegate = nil
            window?.delegate = nil
            window = nil
            webView = nil
        }
    }
}
#endif
