import SwiftUI

/// What the app-owned row above the macOS split view is presenting right now.
internal enum MacTopChromeMode: Equatable {
    /// Sidebar toggle, harness identity chip, model picker, surface icons.
    case chat
    /// An open surface's Back/title header, plus the surface icons.
    case surface
    /// A slim strip whose only control brings the chrome back.
    case collapsed
}

/// Presentation policy for the macOS top chrome row.
///
/// Pure and view-free so the rule worth protecting — collapsing must never take
/// the Back button away — is testable without launching the app (see
/// docs/testing-strategy.md).
internal enum MacTopChrome {
    internal static let expandedHeight: CGFloat = 40

    /// Tall enough to stay an obvious click target and to keep the transcript
    /// clear of the window's traffic lights, short enough to read as "the
    /// toolbar is gone". Matches the collapsed bars on the dashboard canvases.
    internal static let collapsedHeight: CGFloat = 22

    /// `isCollapsed` is the user's stored preference; an open surface overrides
    /// it. The surface header owns Back — and the Escape shortcut attached to it
    /// — so honoring the preference there would strand the user inside a
    /// full-pane surface with no way back to the chat.
    internal static func mode(isSurfaceOpen: Bool, isCollapsed: Bool) -> MacTopChromeMode {
        if isSurfaceOpen { return .surface }
        return isCollapsed ? .collapsed : .chat
    }

    internal static func height(for mode: MacTopChromeMode) -> CGFloat {
        mode == .collapsed ? collapsedHeight : expandedHeight
    }
}
