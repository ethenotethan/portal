import Combine
import Foundation

private let log = PortalLogger(category: "PageIntentDock")

internal enum PageIntentMode: CaseIterable, Equatable, Identifiable, Sendable {
    case chat
    case voice

    internal var id: Self { self }

    internal var title: String {
        switch self {
        case .chat: "Chat"
        case .voice: "Voice"
        }
    }

    internal var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .voice: "waveform.and.mic"
        }
    }
}

/// Drives the "talk to this page" dock: one ordinary Hermes session per page
/// scope (each wiki, the cron graph), preloaded with an ephemeral system prompt
/// and a one-time "load this page's context" turn. Chat and voice remain idle
/// until the user explicitly expands one of them. Never constructs views; the
/// dock view observes it.
@MainActor
internal final class PageIntentDockModel: ObservableObject {
    @Published internal private(set) var isOpen = false
    @Published internal private(set) var activeMode: PageIntentMode?
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
    private var latestContexts: [PageIntentScope: PageIntentContext] = [:]
    private var preparationTasks: [PageIntentScope: Task<Void, Never>] = [:]
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

    /// Prepare the page's ordinary session while the graph itself loads. This
    /// deliberately does not open the dock or start the local voice model.
    internal func preload(context: PageIntentContext) async {
        self.context = context
        await prepareLatest(context: context)
    }

    /// Expand the explicitly selected mode. Preparation is normally already
    /// complete from `preload`; this fallback keeps a direct user action safe if
    /// the graph appeared before the background task could finish.
    internal func open(context: PageIntentContext, mode: PageIntentMode) async {
        openGeneration += 1
        let generation = openGeneration
        pendingContext?.cancel()
        self.context = context
        isOpen = true
        activeMode = mode
        isOpening = true
        status = nil
        defer { if generation == openGeneration { isOpening = false } }

        // One voice conversation at a time: leaving another scope ends its mic.
        if let previous = activeScope, previous != context.scope, let previousChat = chats[previous], previousChat.isConversationActive {
            await previousChat.endConversation()
        }
        activeScope = context.scope
        await prepareLatest(context: context)
        guard generation == openGeneration else { return }
        guard let chat = activeChat else { return }

        switch mode {
        case .chat:
            if chat.isConversationActive {
                await chat.endConversation()
            }
        case .voice:
            if !chat.isConversationActive {
                await chat.startVoiceConversation()
            }
            if !chat.isConversationActive {
                status = "Voice is unavailable here — choose Chat instead."
            }
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
        activeMode = nil
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

    private func prepareLatest(context: PageIntentContext) async {
        let scope = context.scope
        latestContexts[scope] = context
        if let pending = preparationTasks[scope] {
            await pending.value
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.prepareSession(scope: scope)
            await self.applyLatestPreparedContext(scope: scope)
        }
        preparationTasks[scope] = task
        await task.value
        preparationTasks[scope] = nil
    }

    private func prepareSession(scope: PageIntentScope) async {
        guard let backend else {
            status = "No gateway client — connect to the harness first."
            return
        }
        let chat = chats[scope] ?? makeChat()
        chats[scope] = chat
        chat.setGatewayClient(backend)
        if chat.currentSessionID == nil {
            await chat.createSession()
        }
        if chat.currentSessionID == nil {
            status = chat.error ?? "Could not start a session for this page."
        }
    }

    private func applyPreparedContext(_ context: PageIntentContext) async {
        guard let backend, let chat = chats[context.scope], let sessionID = chat.currentSessionID else { return }
        await applyPrompt(context, chat: chat, sessionID: sessionID, backend: backend)
        if !primed.contains(context.scope) {
            chat.inputText = PageIntentPrompt.priming(for: context)
            await chat.submitPrompt()
            primed.insert(context.scope)
        }
    }

    private func applyLatestPreparedContext(scope: PageIntentScope) async {
        while let candidate = latestContexts[scope] {
            do {
                try await Task.sleep(for: Self.contextDebounce)
            } catch {
                return
            }
            guard latestContexts[scope]?.digest == candidate.digest else { continue }
            await applyPreparedContext(candidate)
            guard latestContexts[scope]?.digest == candidate.digest else { continue }
            return
        }
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
