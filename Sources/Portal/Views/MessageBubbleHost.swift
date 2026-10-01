import SwiftUI

/// One transcript bubble, comparable: SwiftUI skips its body when the message's
/// render key, the persona and the skin are unchanged. Without this every
/// bubble re-ran on every streamed delta — the skin providers return `AnyView`,
/// which SwiftUI cannot compare — and a long transcript multiplied each delta
/// by its length.
internal struct MessageBubbleHost: View, Equatable {
    internal let message: ChatMessage
    internal let key: ChatMessageRenderKey
    internal let persona: Persona
    internal let skin: ChatSkin
    /// The provider is derived from `skin`, so it is not part of equality.
    internal let provider: ChatSkinProviding

    internal init(message: ChatMessage, persona: Persona, skin: ChatSkin, provider: ChatSkinProviding) {
        self.message = message
        self.key = ChatMessageRenderKey(message)
        self.persona = persona
        self.skin = skin
        self.provider = provider
    }

    nonisolated internal static func == (lhs: MessageBubbleHost, rhs: MessageBubbleHost) -> Bool {
        lhs.key == rhs.key && lhs.persona == rhs.persona && lhs.skin == rhs.skin
    }

    internal var body: some View {
        provider.messageBubble(message: message, persona: persona)
    }
}
