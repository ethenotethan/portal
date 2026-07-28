#if os(macOS)
import SwiftUI
import AppKit

/// The dropdown content for Portal's menu-bar item (`MenuBarExtra`, `.window`
/// style). A glanceable status panel that stays reachable even when every
/// window is closed — the app deliberately keeps running in the background
/// (see `applicationShouldTerminateAfterLastWindowClosed`), so this is the
/// always-available handle on it.
///
/// It observes the SAME `@StateObject`s the main window does (injected from
/// `MacApp`), so the connection dot and session count are live, not a snapshot.
/// Actions route through the existing `hermesnative://` deep-link scheme — the
/// same path notification taps use — so "New chat" / "Open" reuse the one
/// dispatch in `ContentView.handleDeepLink(_:)` rather than duplicating routing.
internal struct PortalMenuBarContent: View {
    @ObservedObject internal var sessionList: SessionListViewModel
    @ObservedObject internal var gateway: GatewayClientWrapper
    @Environment(\.openURL) private var openURL

    /// Sessions currently mid-run (streaming / working), for the activity line.
    private var runningCount: Int {
        sessionList.sessions.reduce(0) { count, session in
            count + (sessionList.runState(for: session.id)?.isActive == true ? 1 : 0)
        }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            actions
            Divider().padding(.vertical, 6)
            Button("Quit Portal") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 240)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Portal")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Circle()
                    .fill(gateway.isConnected ? Color.green : (gateway.isConnecting ? Color.orange : Color.secondary))
                    .frame(width: 7, height: 7)
                Text(connectionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(sessionSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var connectionLabel: String {
        if gateway.isConnected { return "Connected" }
        if gateway.isConnecting { return "Connecting…" }
        return "Offline"
    }

    private var sessionSummary: String {
        let total = sessionList.sessions.count
        let sessions = total == 1 ? "1 session" : "\(total) sessions"
        return runningCount > 0 ? "\(sessions) · \(runningCount) active" : sessions
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuButton("New chat", systemImage: "square.and.pencil") {
                open(.newSession)
            }
            menuButton("Open Portal", systemImage: "macwindow") {
                PortalMenuBarActivator.openMainWindow()
            }
            menuButton("Activity", systemImage: "bell") {
                open(.activity)
            }
        }
    }

    private func menuButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Route an action through the `hermesnative://` scheme so it lands in the
    /// same `handleDeepLink` dispatch the rest of the app uses. Bring the app
    /// forward first so the result is visible (the window may be closed).
    private func open(_ link: PortalDeepLink) {
        PortalMenuBarActivator.openMainWindow()
        if let url = link.url { openURL(url) }
    }
}

/// AppKit bridge for the menu bar's window-management action. `MenuBarExtra`
/// content has no window of its own, and the app survives its last window
/// closing, so "Open Portal" must re-summon a main window and activate the app.
internal enum PortalMenuBarActivator {
    /// Bring Portal to the front, reopening a main window if all were closed —
    /// mirrors `PortalAppDelegate.applicationShouldHandleReopen`.
    @MainActor
    internal static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
        if hasVisibleWindow {
            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            // No summonable window — ask AppKit to reopen the WindowGroup, the
            // same route a Dock-icon click takes.
            NSApp.sendAction(#selector(NSApplication.arrangeInFront(_:)), to: nil, from: nil)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// The menu-bar label: the app icon at menu-bar size. Uses the live
/// `applicationIconImage` so it always matches whatever icon the build ships —
/// no separate asset to keep in sync. Rendered at 18pt, the macOS menu-bar
/// convention; not a template image, so the logo keeps its colour.
internal struct PortalMenuBarLabel: View {
    internal var body: some View {
        Image(nsImage: Self.menuBarIcon)
    }

    private static let menuBarIcon: NSImage = {
        let source = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        let target = NSSize(width: 18, height: 18)
        let image = NSImage(size: target)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        image.unlockFocus()
        return image
    }()
}
#endif
