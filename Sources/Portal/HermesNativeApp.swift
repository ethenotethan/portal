import SwiftUI
import os

private let log = PortalLogger(category: "PortalApp")

/// Shared app helpers used by the platform-specific @main entry points.
///
/// Keep @StateObject ownership in the concrete App structs. Do not wrap one
/// App inside another App (e.g. `PortalApp().body`), because SwiftUI will
/// access those StateObjects before the owner is installed and create transient
/// instances.
func requestPortalNotificationAuthorization() {
    Task { @MainActor in
        _ = await NotificationService.shared.requestAuthorization()
    }
}

/// Starts debug-only perf instrumentation (memory/CPU sampler, MetricKit).
/// No-op in release builds and unless `--perf` is passed for live sampling.
@MainActor
func startPortalPerfInstrumentation() {
    PerfInstrumentation.bootstrap()
}

/// Starts Portal's declared architecture log sink (`~/Library/Logs/Portal/portal.log`;
/// on iOS the sandbox's own `Library/Logs/Portal/portal.log`): the file every
/// `PortalLogger` line is appended to. Writes the startup line and arranges the
/// final flush; the sink itself works on its own queue, never the main actor.
@MainActor
internal func startPortalLogSink() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    portalLogSink.start(appVersion: version)
}

// MARK: - Session health watchdog

/// The long-session watchdog: a `Health:` line every interval, degraded-state
/// detection, diagnostic bundles under `…/Logs/Portal/diagnostics/`. One per
/// process (a module-level `let`, per the no-singletons rule); tests build
/// their own with injected dependencies.
@MainActor
internal let sessionHealthMonitor = SessionHealthMonitor()

/// Starts sampling at launch. The gateway and session sources bind later, once
/// the App's state objects exist (`attachPortalSessionHealthSources`).
@MainActor
internal func startPortalSessionHealthMonitor() {
    sessionHealthMonitor.setBundleHandler { folder, reasons in
        Task { @MainActor in
            NotificationService.shared.notifyDiagnosticsBundle(folder: folder.path, reasons: reasons)
        }
    }
    sessionHealthMonitor.start()
}

/// Binds the main-actor sources the health sample reads: the gateway's pool and
/// state, the open sessions, the artifacts in memory. Weak so the monitor never
/// keeps the App's objects alive.
@MainActor
internal func attachPortalSessionHealthSources(gateway: GatewayClientWrapper, sessions: SessionListViewModel) {
    sessionHealthMonitor.attachMainActorReader { [weak gateway, weak sessions] in
        var reading = SessionHealthMainActorReading()
        if let gateway {
            let snapshot = gateway.client.diagnosticSnapshot()
            reading.gatewayState = snapshot.connectionState
            reading.pendingRequests = snapshot.pendingRequestCount
            reading.reconnectAttempt = snapshot.reconnectAttempt
            reading.lastRTTms = gateway.lastPingRTT.map { Int($0 * 1000) }
            reading.gatewaySnapshot = GatewayDiagnosticSnapshot(snapshot)
        }
        reading.sessionsOpen = sessions?.sessions.count
        reading.artifactsInMemory = ArtifactStore.shared.artifacts.count
        return reading
    }
}

/// The manual capture (menu item, Settings button): writes a bundle now and,
/// on macOS, reveals the folder in Finder.
@MainActor
internal func capturePortalDiagnostics() async {
    guard let folder = await sessionHealthMonitor.captureNow() else { return }
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([folder])
    #endif
}

#if os(macOS)
import AppKit

@MainActor
func configurePortalMacApplication() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
}

/// Applies the macOS window chrome configuration SwiftUI does not expose.
/// This intentionally keeps the standard red/yellow/green window controls
/// visible while allowing the app content to extend behind a transparent titlebar.
struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.styleMask.remove(.borderless)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.background)
        window.showsResizeIndicator = false

        // Do not hide or remove the standard close/minimize/zoom buttons.
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(buttonType) {
                button.isHidden = false
                button.alphaValue = 1
                button.isEnabled = true
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
            }
        }

        logWindowDiagnostics(window)
    }

    private func logWindowDiagnostics(_ window: NSWindow) {
        #if DEBUG
        // assumeIsolated, not `Task { @MainActor }`: main.async already
        // guarantees the main thread, so this only tells the compiler what is
        // already true — the whole dump (NSApp, view frames, subviews) is
        // main-actor state — without changing when the hop happens.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let w = NSApp.windows.first else { return }
                log.debug("=== HERMES WINDOW ===")
                log.debug("frame: \(String(describing: w.frame)) styleMask: \(w.styleMask.rawValue)")
                log.debug("titlebarTransparent: \(w.titlebarAppearsTransparent)")
                log.debug("titleVisibility: \(w.titleVisibility.rawValue)")
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let b = w.standardWindowButton(kind)
                    log.debug("""
                    \(kind.rawValue): \
                    \(String(describing: b)) \
                    hidden: \(String(describing: b?.isHidden)) \
                    alpha: \(String(describing: b?.alphaValue)) \
                    frame: \(String(describing: b?.frame ?? .zero)) \
                    superview: \(String(describing: b?.superview.map { type(of: $0) })) \
                    superFrame: \(String(describing: b?.superview?.frame ?? .zero))
                    """)
                }
                log.debug("=== HERMES CONTENT VIEW HIERARCHY ===")
                // A nested func does NOT inherit the enclosing closure's actor
                // isolation, so this needs its own annotation even inside
                // assumeIsolated — every line of it reads main-actor view state.
                @MainActor
                func dump(_ v: NSView, _ depth: Int = 0) {
                    let pad = String(repeating: "  ", count: depth)
                    let frameStr = String(describing: v.frame)
                    let boundsStr = String(describing: v.bounds)
                    log.debug("\(pad)\(type(of: v)) frame=\(frameStr) bounds=\(boundsStr) hidden=\(v.isHidden) alpha=\(v.alphaValue) subviews=\(v.subviews.count)")
                    v.subviews.forEach { dump($0, depth + 1) }
                }
                if let cv = w.contentView { dump(cv) }
            }
        }
        #endif
    }
}
#endif
