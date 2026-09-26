import Combine
import Foundation

private let log = PortalLogger(category: "PageIntentDock")

/// Drives the "talk to this page" dock: one ordinary Hermes session per page
/// scope (each wiki, the cron graph), created lazily, given an ephemeral system
/// prompt that describes the page, primed once with a "load this page's
/// context" turn, and put into a hands-free voice conversation so the user can
/// start talking. Never constructs views; the dock view observes it.
@MainActor
internal final class PageIntentDockModel: ObservableObject {
    @Published internal private(set) var isOpen = false
    @Published internal private(set) var activeScope: PageIntentScope?
    @Published internal private(set) var context: PageIntentContext?
    /// One line for the dock header: why voice is not running, or nothing.
    @Published internal private(set) var status: String?
    @Published internal private(set) var isOpening = false

    /// How long the page may keep changing before the prompt is refreshed.
    internal static let contextDebounce: Duration = .milliseconds(500)

    private var backend: (any AgentBackend)?
    private var chats: [PageIntentScope: ChatViewModel] = [:]
    private var primed: Set<PageIntentScope> = []
    private var promptDigests: [PageIntentScope: String] = [:]
    private var pendingContext: Task<Void, Never>?
    private var openGeneration = 0
    /// Injected so tests can hand back a chat wired to a spy; the app uses the
    /// default, a fresh `ChatViewModel` bound to the app's gateway client.
    internal var makeChat: () -> ChatViewModel = { ChatViewModel() }
    /// How "Open in Chat" reaches the chat page. The default posts the app's
    /// switch-to-session notification, which the chat surface already handles.
    internal var onOpenInChat: (String) -> Void = { sessionID in
        NotificationCenter.default.post(name: .hermesSwitchToSession, object: nil, userInfo: ["session_id": sessionID])
    }

    internal init() {}

    /// The chat the dock renders: the active scope's session, once opened.
    internal var activeChat: ChatViewModel? {
        activeScope.flatMap { chats[$0] }
    }

    /// Bind the gateway client before the first open. Idempotent.
    internal func configure(backend: any AgentBackend) {
        self.backend = backend
    }

    /// Open the dock on a page: create the scope's session if needed, set the
    /// page prompt, prime the session once, and start listening.
    internal func open(context: PageIntentContext) async {
        openGeneration += 1
        let generation = openGeneration
        pendingContext?.cancel()
        self.context = context
        isOpen = true
        isOpening = true
        status = nil
        defer { if generation == openGeneration { isOpening = false } }

        guard let backend else {
            status = "No gateway client — connect to the harness first."
            return
        }
        // One voice conversation at a time: leaving another scope ends its mic.
        if let previous = activeScope, previous != context.scope, let previousChat = chats[previous], previousChat.isConversationActive {
            await previousChat.endConversation()
        }
        activeScope = context.scope

        let chat = chats[context.scope] ?? makeChat()
        chats[context.scope] = chat
        chat.setGatewayClient(backend)
        if chat.currentSessionID == nil {
            await chat.createSession()
        }
        guard generation == openGeneration else { return }
        guard let sessionID = chat.currentSessionID else {
            status = chat.error ?? "Could not start a session for this page."
            return
        }
        await applyPrompt(context, chat: chat, sessionID: sessionID, backend: backend)
        guard generation == openGeneration else { return }
        if !primed.contains(context.scope) {
            chat.inputText = PageIntentPrompt.priming(for: context)
            await chat.submitPrompt()
            primed.insert(context.scope)
        }
        guard generation == openGeneration else { return }
        await chat.startVoiceConversation()
        if !chat.isConversationActive {
            status = "Voice is unavailable here — type below."
        }
    }

    /// The page changed while the dock is open: refresh the prompt after the
    /// page settles, and only when the state actually differs. Never re-primes.
    internal func updateContext(_ context: PageIntentContext) {
        guard isOpen else { return }
        self.context = context
        pendingContext?.cancel()
        pendingContext = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.contextDebounce)
            } catch {
                return // cancelled: a newer context superseded this one
            }
            guard let self else { return }
            await self.refreshPrompt(context)
        }
    }

    /// Wait for a pending debounced context refresh to land (tests; a no-op
    /// when nothing is pending). Deterministic where a wall-clock sleep is not.
    internal func settleContext() async {
        await pendingContext?.value
    }

    /// Apply a context's prompt immediately (no debounce). Exposed for tests.
    internal func refreshPrompt(_ context: PageIntentContext) async {
        guard let backend, let chat = chats[context.scope], let sessionID = chat.currentSessionID else { return }
        await applyPrompt(context, chat: chat, sessionID: sessionID, backend: backend)
    }

    /// Close the dock: stop listening, keep the session so reopening continues it.
    internal func close() async {
        pendingContext?.cancel()
        openGeneration += 1
        isOpen = false
        isOpening = false
        if let chat = activeChat, chat.isConversationActive {
            await chat.endConversation()
        }
    }

    /// Hand the active session to the chat page.
    internal func openInChat() {
        guard let sessionID = activeChat?.currentSessionID else { return }
        onOpenInChat(sessionID)
    }

    /// The scopes that already hold a session, for tests and diagnostics.
    internal var openScopes: [PageIntentScope] {
        chats.keys.sorted { $0.id < $1.id }
    }

    /// `session.set_prompt` sets the whole ephemeral prompt, so the page's
    /// context is appended to the chat's own base prompt, never put in its place.
    private func applyPrompt(_ context: PageIntentContext, chat: ChatViewModel, sessionID: String, backend: any AgentBackend) async {
        let digest = context.digest
        guard promptDigests[context.scope] != digest else { return }
        do {
            let prompt = chat.baseEphemeralPrompt() + "\n\n" + PageIntentPrompt.system(for: context)
            try await backend.setEphemeralPrompt(sessionID: sessionID, prompt: prompt)
            promptDigests[context.scope] = digest
        } catch {
            log.error("page intent prompt failed for \(context.scope.id): \(error.localizedDescription)")
            status = "Could not send the page context: \(error.localizedDescription)"
        }
    }
}
