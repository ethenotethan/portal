import SwiftUI

/// TUI skin — braille spinners, tree rails, chevron accordions.
/// The original Portal visual language, aligned with the Ink TUI.
internal struct TUISkin: ChatSkinProviding {
    internal let skin: ChatSkin = .tui

    internal func messageBubble(message: ChatMessage, persona: Persona) -> AnyView {
        // Reuse the existing TUI-aligned MessageBubbleView
        MessageBubbleView(message: message)
            .eraseToAnyView()
    }

    internal func streamingPanel(
        state: AvatarState,
        activeToolCalls: [String: ToolCallRecord],
        personaName: String,
        accentColor: Color
    ) -> AnyView {
        StreamingStatusBar(
            state: state,
            activeToolCalls: activeToolCalls,
            personaName: personaName,
            accentColor: accentColor
        )
        .eraseToAnyView()
    }
}
