import Testing
@testable import Portal

/// Render contracts live in the client prompt — the gateway teaches the agent
/// nothing about Portal's surfaces. These pin the parts of the prompt that
/// pair with host-side input handling, where silent drift produces artifacts
/// that fight the host instead of failing visibly.
@Suite("App formatting prompt")
@MainActor
internal struct FormattingPromptTests {
    private var prompt: String { ChatViewModel.appFormattingPrompt }

    @Test("teaches the Pointer Lock input contract for interactive HTML worlds")
    internal func teachesPointerLockContract() {
        // The host captures the mouse (HTMLPointerLockBridge) and hides the
        // cursor, so a generated world using click-and-drag as its primary
        // camera scheme is unusable — the exact "having to click and drag when
        // I shouldn't" complaint. The prompt must steer generation toward
        // movementX/movementY while locked.
        #expect(prompt.contains("movementX"))
        #expect(prompt.contains("pointerLockElement"))
        #expect(prompt.contains("NEVER implement click-and-drag camera controls"))
    }

    @Test("teaches keyboard movement and the host's Escape ownership")
    internal func teachesKeyboardContract() {
        // keydown/keyup on document — the canvas is not guaranteed focus.
        #expect(prompt.contains("keydown"))
        #expect(prompt.contains("WASD"))
        // Esc is two-stage host chrome (release, then exit); a world that
        // binds it fights the release gesture.
        #expect(prompt.contains("Do not bind Escape"))
    }

    @Test("teaches HUD overlays to pass clicks through to the scene")
    internal func teachesHUDPassthrough() {
        // The capture bridge falls back to the dominant canvas, but overlays
        // that swallow pointer events still block direct canvas interaction —
        // pointer-events: none is the belt to the bridge's suspenders.
        #expect(prompt.contains("pointer-events: none"))
    }
}
