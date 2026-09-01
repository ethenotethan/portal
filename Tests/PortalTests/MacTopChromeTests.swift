import Testing
@testable import Portal

@Suite("macOS top chrome collapse")
internal struct MacTopChromeTests {
    @Test("Chat presents the full chrome row by default")
    internal func chatShowsFullChrome() {
        #expect(MacTopChrome.mode(isSurfaceOpen: false, isCollapsed: false) == .chat)
    }

    @Test("Collapsing the chrome leaves only the reveal strip over the chat")
    internal func collapsedChatShowsStrip() {
        #expect(MacTopChrome.mode(isSurfaceOpen: false, isCollapsed: true) == .collapsed)
    }

    @Test("An open surface keeps its header even while the chrome is collapsed")
    internal func openSurfaceOverridesCollapse() {
        // The header owns Back (and the Escape shortcut hanging off it), so
        // honoring the preference here would strand the user in the surface.
        #expect(MacTopChrome.mode(isSurfaceOpen: true, isCollapsed: true) == .surface)
        #expect(MacTopChrome.mode(isSurfaceOpen: true, isCollapsed: false) == .surface)
    }

    @Test("Only the collapsed strip is shorter than the chrome row")
    internal func collapsedModeIsTheShortRow() {
        #expect(MacTopChrome.height(for: .collapsed) == MacTopChrome.collapsedHeight)
        #expect(MacTopChrome.height(for: .chat) == MacTopChrome.expandedHeight)
        #expect(MacTopChrome.height(for: .surface) == MacTopChrome.expandedHeight)
        #expect(MacTopChrome.collapsedHeight < MacTopChrome.expandedHeight)
    }

    @Test("The collapsed strip stays a clickable target rather than vanishing")
    internal func collapsedStripRemainsHittable() {
        // A zero-height row would hide the only way back to the chrome.
        #expect(MacTopChrome.collapsedHeight >= 18)
    }
}
