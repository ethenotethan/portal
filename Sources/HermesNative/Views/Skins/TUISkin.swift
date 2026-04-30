import SwiftUI

/// TUI skin — braille spinners, tree rails, chevron accordions.
/// The original HermesNative visual language, aligned with the Ink TUI.
struct TUISkin: ChatSkinProviding {
    let skin: ChatSkin = .tui

    func messageBubble(message: ChatMessage, persona: Persona) -> AnyView {
        // Reuse the existing TUI-aligned MessageBubbleView
        MessageBubbleView(message: message)
            .eraseToAnyView()
    }

    func streamingPanel(
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
