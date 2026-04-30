import SwiftUI

/// Selectable chat interface skins. Each skin provides a complete visual
/// personality for the chat view — message bubbles, streaming indicators,
/// tool call rendering, background colors, and layout.
enum ChatSkin: String, CaseIterable, Identifiable, Sendable {
    case tui = "tui"
    case darkManga = "dark_manga"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tui: return "TUI"
        case .darkManga: return "Dark Manga"
        }
    }

    var icon: String {
        switch self {
        case .tui: return "terminal"
        case .darkManga: return "paintbrush"
        }
    }

    /// Background color for the chat area
    var background: Color {
        switch self {
        case .tui: return Color(nsColor: .windowBackgroundColor)
        case .darkManga: return Theme.background
        }
    }
}

// MARK: - Skin Protocol

/// A skin provides the key visual components for the chat interface.
/// Marked @preconcurrency to allow non-Sendable AnyView returns from
/// MainActor-isolated skins.
@preconcurrency
protocol ChatSkinProviding: Sendable {
    var skin: ChatSkin { get }

    /// Render a chat message bubble
    @MainActor func messageBubble(message: ChatMessage, persona: Persona) -> AnyView

    /// Render the streaming/active state (thinking, tools, etc.)
    @MainActor func streamingPanel(
        state: AvatarState,
        activeToolCalls: [String: ToolCallRecord],
        personaName: String,
        accentColor: Color
    ) -> AnyView
}

// MARK: - Skin Factory

extension ChatSkin {
    /// Create the skin provider for this skin type
    func makeProvider() -> ChatSkinProviding {
        switch self {
        case .tui: return TUISkin()
        case .darkManga: return DarkMangaSkin()
        }
    }
}

// MARK: - Type eraser helper

extension View {
    @MainActor func eraseToAnyView() -> AnyView { AnyView(self) }
}
