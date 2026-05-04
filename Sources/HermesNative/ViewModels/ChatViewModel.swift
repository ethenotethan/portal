import Foundation
import Combine

/// Core chat ViewModel — manages conversation state and interacts with the gateway.
@MainActor
final class ChatViewModel: ObservableObject {
    private struct ChatSessionState {
        var sessionID: String
        var messages: [ChatMessage]
        var isStreaming: Bool
        var streamingMessageID: UUID?
        var activeToolCalls: [String: ToolCallRecord]
        var pendingApproval: ApprovalPayload?
        var avatarState: AvatarState
        var error: String?
        var sessionTitle: String
        var currentModel: String
    }

    // MARK: - App Formatting Prompt
    // Injected as ephemeral system prompt so the model uses mermaid diagrams
    // and rich markdown — matching the app's native rendering capabilities.

    static let appFormattingPrompt = """
    ## Response Formatting (HermesNative App)

    You are running inside a native app that renders rich markdown and Mermaid diagrams. Use these capabilities:

    - **Mermaid diagrams** for architecture, data flows, protocol sequences, call chains, state machines, component relationships, or any "how does X connect to Y" question. Use the appropriate type: flowchart, sequenceDiagram, graph, stateDiagram-v2, classDiagram. Wrap in ```mermaid blocks. One concept per diagram.
    - **Markdown headings** (##, ###) to structure longer responses
    - **Bold** for key terms, *italic* for emphasis
    - **Code blocks** with language tags (```python, ```swift, ```bash)
    - **Ordered/unordered lists** for steps and enumerations
    - **Blockquotes** for important callouts

    Prefer diagram-first: when a visual explanation is possible, lead with the Mermaid diagram, then explain in prose.
    """
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var isSessionReady: Bool = false
    @Published var currentModel: String = ""
    @Published var pendingApproval: ApprovalPayload?
    @Published var activeToolCalls: [String: ToolCallRecord] = [:] // tool_id → record
    @Published var error: String?
    @Published var avatarState: AvatarState = .idle
    @Published var sessionTitle: String = "New Chat"
    @Published private(set) var createGeneration: Int = 0

    private var gatewayClient: GatewayClient?
    private var sessionID: String?
    private var stableSessionByGatewayID: [String: String] = [:]
    private var sessionStates: [String: ChatSessionState] = [:]
    private var streamingMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
    /// Monotonic token for user-driven session switches/creates. Async resume
    /// calls must check this before committing returned history; otherwise a
    /// slower first resume can overwrite the newer selected session after rapid
    /// double-clicks in the sidebar.
    private var sessionSwitchGeneration = 0
    private var isCreatingSession = false  // Guard against double-trigger
    private var isStopping = false
    weak var personaManager: PersonaManager?

    // MARK: - Setup

    func setGatewayClient(_ client: GatewayClient) {
        // ContentView can wire the same app-level client repeatedly during
        // connect/session-create flows. Avoid stacking duplicate Combine
        // subscriptions, because every gateway event would otherwise be applied
        // N times and parallel sessions quickly corrupt local chat state.
        guard gatewayClient !== client else { return }

        cancellables.removeAll()
        gatewayClient = client

        // Subscribe to gateway events. Events are multiplexed over one app-level
        // WebSocket. Events for the visible session update the published view
        // state; events for known background sessions update their cached state
        // so an actively-running session can continue while the user opens
        // another chat.
        client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, eventSessionID in
                self?.handleEvent(event, eventSessionID: eventSessionID)
            }
            .store(in: &cancellables)

        // Observe connection state
        client.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    self?.error = nil
                case .reconnecting:
                    self?.error = nil  // Clear errors — reconnect in progress
                    // Do not mark the active turn as stopped during a transient
                    // iOS background/reconnect. The gateway agent may still be
                    // running, and clearing isStreaming here makes later live
                    // frames look like stale post-stop events.
                    if self?.isStreaming == true {
                        self?.avatarState = .thinking
                    }
                case .error(let msg):
                    self?.error = msg
                    if self?.sessionID == nil {
                        self?.isSessionReady = false
                    }
                    if self?.isStreaming == true {
                        self?.avatarState = .error
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Observe session info
        client.$sessionInfo
            .receive(on: RunLoop.main)
            .sink { [weak self] info in
                if let info = info {
                    self?.currentModel = info.model
                }
            }
            .store(in: &cancellables)

        // Handle reconnection. Session creation is explicit from the Sessions UI;
        // reconnect should not implicitly create an invisible chat that races with
        // the New Session button and leaves the list empty on compact iOS.
        client.onReconnected = { [weak self] in
            guard let self else { return }
            // Sync persona
            if let pm = self.personaManager, let client = self.gatewayClient {
                await pm.syncFromGateway(client)
            }
            // If GatewayClient already resumed the session, use that session ID
            if let resumedID = self.gatewayClient?.activeSessionID {
                if self.sessionID != resumedID {
                    let oldKey = self.visibleStateKey()
                    self.sessionID = resumedID
                    if let oldKey {
                        self.stableSessionByGatewayID[resumedID] = oldKey
                    }
                }
                self.createGeneration += 1
                self.isSessionReady = true
                self.error = nil
                self.snapshotCurrentSession()
            }
        }
    }

    /// The session ID currently active in this chat view.
    var currentSessionID: String? { sessionID }

    /// Test/debug hook for applying a gateway event exactly as the shared
    /// WebSocket subscriber would receive it.
    func receiveGatewayEventForTesting(_ event: GatewayEvent, sessionID: String?) {
        handleEvent(event, eventSessionID: sessionID)
    }

    /// Link the active short-lived gateway ID with the stable database ID shown
    /// in the sessions list. History is saved under both IDs so switching away
    /// and back does not depend on which ID is current at that exact moment.
    func bindCurrentGatewaySession(toStableSessionID stableID: String) {
        guard let gatewayID = sessionID, !stableID.isEmpty else { return }
        let oldKey = stateKey(for: gatewayID)
        stableSessionByGatewayID[gatewayID] = stableID
        if oldKey != stableID, let oldState = sessionStates.removeValue(forKey: oldKey) {
            var mergedState = oldState
            if let existingStableState = sessionStates[stableID] {
                let stableHasLiveTurn = existingStableState.isStreaming
                    || existingStableState.streamingMessageID != nil
                    || !existingStableState.activeToolCalls.isEmpty
                    || existingStableState.pendingApproval != nil
                if stableHasLiveTurn {
                    mergedState = existingStableState
                }
            }
            mergedState.sessionID = gatewayID
            sessionStates[stableID] = mergedState
        }
        snapshotCurrentSession()
        if !messages.isEmpty {
            ChatHistoryStore.shared.saveMessages(messages, forSession: stableID)
        }
    }

    private func stableSessionID(forGatewayID gatewayID: String) -> String? {
        stableSessionByGatewayID[gatewayID]
    }

    private func stateKey(for sessionID: String) -> String {
        stableSessionID(forGatewayID: sessionID) ?? sessionID
    }

    private func keyForIncomingEvent(sessionID eventSessionID: String) -> String {
        if let stableID = stableSessionID(forGatewayID: eventSessionID) {
            return stableID
        }
        if sessionStates[eventSessionID] != nil {
            return eventSessionID
        }
        if let match = sessionStates.first(where: { $0.value.sessionID == eventSessionID }) {
            return match.key
        }
        return eventSessionID
    }

    private func publishVisibleStateIfNeeded(for key: String, previousVisibleKey: String?) {
        guard key == previousVisibleKey, let state = sessionStates[key] else { return }
        restoreState(state)
    }

    private func snapshotCurrentSession() {
        guard let sid = sessionID else { return }
        sessionStates[stateKey(for: sid)] = ChatSessionState(
            sessionID: sid,
            messages: messages,
            isStreaming: isStreaming,
            streamingMessageID: streamingMessageID,
            activeToolCalls: activeToolCalls,
            pendingApproval: pendingApproval,
            avatarState: avatarState,
            error: error,
            sessionTitle: sessionTitle,
            currentModel: currentModel
        )
    }

    private func restoreState(_ state: ChatSessionState) {
        sessionID = state.sessionID
        messages = state.messages
        isStreaming = state.isStreaming
        streamingMessageID = state.streamingMessageID
        activeToolCalls = state.activeToolCalls
        pendingApproval = state.pendingApproval
        avatarState = state.avatarState
        error = state.error
        sessionTitle = state.sessionTitle
        currentModel = state.currentModel
        isSessionReady = true
    }

    private func visibleStateKey() -> String? {
        sessionID.map { stateKey(for: $0) }
    }

    private func applyEvent(_ event: GatewayEvent, to state: inout ChatSessionState) {
        if event.isLiveTurnEvent && !state.isStreaming {
            if case .messageStart = event {
                state.isStreaming = true
            } else {
                return
            }
        }

        switch event {
        case .sessionInfo(let info):
            state.currentModel = info.model

        case .messageStart:
            if state.streamingMessageID == nil {
                let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
                state.streamingMessageID = assistantMessage.id
                state.messages.append(assistantMessage)
            }
            state.avatarState = .speaking

        case .messageDelta(let text, _):
            if let msgID = state.streamingMessageID,
               let idx = state.messages.firstIndex(where: { $0.id == msgID }) {
                state.messages[idx].content += text
            }

        case .messageComplete(payload: let payload):
            guard let msgID = state.streamingMessageID,
                  let idx = state.messages.firstIndex(where: { $0.id == msgID }) else {
                state.activeToolCalls = [:]
                return
            }
            state.messages[idx].content = payload.text
            state.messages[idx].isStreaming = false
            state.messages[idx].usage = payload.usage
            state.messages[idx].status = payload.status
            state.messages[idx].reasoning = payload.reasoning
            state.messages[idx].toolCalls = Array(state.activeToolCalls.values)
            state.activeToolCalls = [:]
            state.isStreaming = false
            state.streamingMessageID = nil
            state.avatarState = .idle

        case .toolStart(payload: let payload):
            state.avatarState = .toolUse
            state.activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context
            )

        case .toolComplete(payload: let payload):
            if var record = state.activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                state.activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            for (key, var record) in state.activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                state.activeToolCalls[key] = record
            }

        case .reasoningDelta(let text):
            if state.avatarState != .toolUse { state.avatarState = .thinking }
            if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                state.messages[idx].reasoning = (state.messages[idx].reasoning ?? "") + text
            }

        case .thinkingDelta(let text):
            if state.avatarState != .toolUse { state.avatarState = .thinking }
            if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                let existing = state.messages[idx].reasoning ?? ""
                let separator = existing.isEmpty ? "" : "\n"
                state.messages[idx].reasoning = existing + separator + text
            }

        case .approvalRequest(payload: let payload):
            state.pendingApproval = payload

        case .error(let message):
            state.error = message
            state.isStreaming = false
            state.avatarState = .error

        default:
            break
        }
    }

    /// Create a new session on the gateway.
    func createSession() async {
        guard let client = gatewayClient else {
            self.error = "No gateway client"
            return
        }
        NSLog("[HermesNative] ChatViewModel createSession invoked state=\(client.connectionState)")
        guard !isCreatingSession else {
            NSLog("[HermesNative] ChatViewModel createSession ignored: already creating")
            return
        }
        isCreatingSession = true
        sessionSwitchGeneration += 1
        do {
            let sid = try await client.createSession()
            NSLog("[HermesNative] ChatViewModel createSession succeeded sid=\(sid)")
            self.sessionID = sid
            self.createGeneration += 1
            self.isSessionReady = true
            self.messages = []
            self.activeToolCalls = [:]
            self.pendingApproval = nil
            self.streamingMessageID = nil
            self.error = nil
            self.avatarState = .idle
            self.sessionTitle = "New Chat"
            self.snapshotCurrentSession()

            // Inject the app's formatting prompt so the model uses mermaid + rich markdown
            if let personaSuffix = personaManager?.activePersona.systemPromptSuffix,
               !personaSuffix.isEmpty {
                // Merge persona suffix with app formatting prompt
                let combined = Self.appFormattingPrompt + "\n\n" + personaSuffix
                try? await client.setEphemeralPrompt(sessionID: sid, prompt: combined)
            } else {
                try? await client.setEphemeralPrompt(sessionID: sid, prompt: Self.appFormattingPrompt)
            }
        } catch {
            self.error = "Session create failed: \(error.localizedDescription)"
        }
        isCreatingSession = false
    }

    /// Resume an existing session by key, replacing the current chat state.
    @discardableResult
    func resumeSession(key: String) async -> Bool {
        sessionSwitchGeneration += 1
        let generation = sessionSwitchGeneration
        return await resumeSession(key: key, generation: generation)
    }

    /// Starts a user-visible switch immediately from local cache and returns a
    /// generation token. Call `resumeSession(key:generation:)` to revalidate the
    /// same selection from the gateway; stale generations are ignored.
    @discardableResult
    func beginSwitchToSession(key: String) -> Int {
        snapshotCurrentSession()
        sessionSwitchGeneration += 1
        let generation = sessionSwitchGeneration
        if let cachedState = sessionStates[key] {
            restoreState(cachedState)
        } else if !loadLocalHistory(sessionID: key) {
            // Still bind the selected session immediately, even when no local
            // cache exists. Otherwise the previous chat remains visible while
            // session.resume is in flight, and if the gateway later returns an
            // empty/unsupported history shape the selected prior session can look
            // blank or like it never opened.
            sessionID = key
            messages = []
            isSessionReady = true
            isStreaming = false
            streamingMessageID = nil
            activeToolCalls = [:]
            pendingApproval = nil
            avatarState = .idle
            error = nil
            sessionTitle = "New Chat"
            snapshotCurrentSession()
        }
        return generation
    }

    @discardableResult
    func resumeSession(key: String, generation: Int) async -> Bool {
        guard let client = gatewayClient else {
            if generation == sessionSwitchGeneration {
                self.error = "No gateway client"
            }
            return false
        }
        guard case .connected = client.connectionState else {
            if generation == sessionSwitchGeneration {
                self.error = "Not connected to gateway"
            }
            return false
        }

        let stableSessionID = key
        let cachedBeforeResume = ChatHistoryStore.shared.loadMessages(forSession: stableSessionID)

        do {
            let result = try await client.resumeSession(key: stableSessionID)
            guard generation == sessionSwitchGeneration else {
                NSLog("[HermesNative] ignoring stale resume for \(stableSessionID) generation=\(generation) current=\(sessionSwitchGeneration)")
                return false
            }

            let previousSessionID = self.sessionID
            self.sessionID = result.sessionID
            self.stableSessionByGatewayID[result.sessionID] = stableSessionID
            if let previousSessionID, previousSessionID != result.sessionID, self.stateKey(for: previousSessionID) == stableSessionID {
                self.stableSessionByGatewayID[previousSessionID] = stableSessionID
            }

            var preservedState = self.sessionStates[stableSessionID]
            if let runtimeState = self.sessionStates.removeValue(forKey: result.sessionID), preservedState == nil {
                preservedState = runtimeState
            }
            if let previousSessionID, previousSessionID != result.sessionID,
               let runtimeState = self.sessionStates.removeValue(forKey: previousSessionID),
               preservedState == nil {
                preservedState = runtimeState
            }
            if var preservedState {
                preservedState.sessionID = result.sessionID
                self.sessionStates[stableSessionID] = preservedState
                let hasLiveState = preservedState.isStreaming
                    || preservedState.streamingMessageID != nil
                    || !preservedState.activeToolCalls.isEmpty
                    || preservedState.pendingApproval != nil
                if hasLiveState {
                    self.restoreState(preservedState)
                    self.sessionID = result.sessionID
                    self.stableSessionByGatewayID[result.sessionID] = stableSessionID
                    self.isSessionReady = true
                    self.error = nil
                    self.snapshotCurrentSession()
                    return true
                }
            }
            self.isSessionReady = true

            self.activeToolCalls = [:]
            self.isStreaming = false
            self.streamingMessageID = nil
            self.avatarState = .idle
            self.error = nil

            let parsedGatewayMessages = Self.parseHistoryMessages(result.messages)
            if !parsedGatewayMessages.isEmpty {
                self.messages = parsedGatewayMessages
                ChatHistoryStore.shared.saveMessages(parsedGatewayMessages, forSession: stableSessionID)
            } else if let cachedBeforeResume {
                self.messages = cachedBeforeResume
            } else {
                self.messages = []
            }

            // Keep an immediate local copy under the new short hex ID too, because
            // live prompt/tool RPCs use that ID until session.title resolves again.
            if !self.messages.isEmpty {
                ChatHistoryStore.shared.saveMessages(self.messages, forSession: result.sessionID)
            }
            self.snapshotCurrentSession()

            // Re-inject the app's formatting prompt on resume. Do not let this
            // later RPC overwrite state for a newer selection.
            try? await client.setEphemeralPrompt(sessionID: result.sessionID, prompt: Self.appFormattingPrompt)
            return true
        } catch {
            if generation == sessionSwitchGeneration {
                self.error = "Session resume failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// Load history for the current session (for reconnects where resume isn't used).
    func loadSessionHistory() async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        do {
            let historyMessages = try await client.sessionHistory(sessionID: sid)
            let parsed = Self.parseHistoryMessages(historyMessages)
            if !parsed.isEmpty {
                self.messages = parsed
            }
        } catch {
            // Non-critical — show what we have
        }
    }

    /// Parse gateway history messages into ChatMessage array.
    /// Gateway history has used a few shapes over time: direct `text`, `content`,
    /// OpenAI-style `content`, and tool fields nested under `context`/`result`.
    /// Be permissive here so old sessions do not render as an empty chat on iOS.
    private static func parseHistoryMessages(_ rawMessages: [[String: AnyCodable]]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var currentToolCalls: [ToolCallRecord] = []

        for raw in rawMessages {
            guard let roleStr = raw["role"]?.stringValue?.lowercased() else { continue }

            switch roleStr {
            case "user", "human":
                let text = historyText(from: raw)
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .user, content: text))

            case "assistant", "ai", "model":
                // Flush any pending tool calls before this assistant message.
                if !currentToolCalls.isEmpty {
                    if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                        messages[lastIdx].toolCalls = currentToolCalls
                    }
                    currentToolCalls = []
                }

                let text = historyText(from: raw)
                guard !text.isEmpty else { continue }
                let reasoning = raw["reasoning"]?.stringValue ?? raw["thinking"]?.stringValue
                messages.append(ChatMessage(role: .assistant, content: text, reasoning: reasoning, status: "complete"))

            case "tool", "function":
                let name = raw["name"]?.stringValue
                    ?? raw["tool_name"]?.stringValue
                    ?? raw["function_name"]?.stringValue
                    ?? "tool"
                let context = historyText(from: raw)
                let toolID = raw["tool_id"]?.stringValue
                    ?? raw["id"]?.stringValue
                    ?? "hist_\(messages.count)_\(currentToolCalls.count)"
                currentToolCalls.append(ToolCallRecord(
                    id: toolID,
                    name: name,
                    context: context.isEmpty ? nil : context,
                    summary: context.isEmpty ? nil : context,
                    isComplete: true
                ))

            case "system":
                // System prompts are not chat transcript messages.
                continue

            default:
                break
            }
        }

        // Flush remaining tool calls.
        if !currentToolCalls.isEmpty {
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastIdx].toolCalls = currentToolCalls
            }
        }

        return messages
    }

    private static func historyText(from raw: [String: AnyCodable]) -> String {
        for key in ["text", "content", "message", "output", "result", "context"] {
            if let text = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }

        // Some OpenAI-compatible histories store content as arrays like
        // [{"type":"text", "text":"..."}]. Join text-like fields rather than
        // dropping the entire message.
        if let parts = raw["content"]?.arrayValue {
            let text = parts.compactMap { part -> String? in
                if let text = part.stringValue {
                    return text
                }
                guard let dict = part.dictionaryValue else { return nil }
                return dict["text"]?.stringValue
                    ?? dict["content"]?.stringValue
                    ?? dict["output"]?.stringValue
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        if let arguments = raw["arguments"]?.dictionaryValue {
            return arguments
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayString)" }
                .joined(separator: "\n")
        }

        return ""
    }

    // MARK: - User Input

    /// Send the current input text as a prompt.
    func submitPrompt() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = gatewayClient, let sid = sessionID else { return }
        guard !isStreaming && !isStopping else {
            NSLog("[HermesNative] ChatViewModel submitPrompt ignored while streaming/stopping")
            return
        }

        inputText = ""
        isStreaming = true

        // Add user message to conversation
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)

        // Auto-title from first user message
        if messages.filter({ $0.role == .user }).count == 1 {
            sessionTitle = String(text.prefix(60))
        }

        // Persist user message immediately
        saveHistory()

        // Prepare streaming assistant message
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        )
        streamingMessageID = assistantMessage.id
        messages.append(assistantMessage)
        snapshotCurrentSession()

        do {
            try await client.submitPrompt(sessionID: sid, text: text)
        } catch {
            self.error = error.localizedDescription
            finishStreaming(status: "error")
        }
    }

    /// Interrupt the current agent turn.
    func interrupt() async {
        guard !isStopping else { return }
        guard let client = gatewayClient, let sid = sessionID else {
            finishStreaming(status: "interrupted")
            return
        }

        isStopping = true
        defer { isStopping = false }

        // Update the UI immediately. On iOS this avoids the Stop button looking
        // dead while the gateway waits for the in-flight turn to unwind.
        finishStreaming(status: "interrupted")

        do {
            try await client.interrupt(sessionID: sid)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finishStreaming(status: String? = nil) {
        if let msgID = streamingMessageID,
           let idx = messages.firstIndex(where: { $0.id == msgID }) {
            messages[idx].isStreaming = false
            if let status {
                messages[idx].status = status
            }
            if messages[idx].content.isEmpty && status == "interrupted" {
                messages[idx].content = "_Interrupted_"
            }
        }
        activeToolCalls = [:]
        isStreaming = false
        streamingMessageID = nil
        avatarState = .idle
        saveHistory()
        snapshotCurrentSession()
    }

    /// Respond to a pending approval.
    func respondApproval(choice: String) async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        pendingApproval = nil
        do {
            try await client.respondApproval(sessionID: sid, choice: choice)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Switch the model.
    func switchModel(_ model: String) async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        do {
            try await client.setConfig(key: "model", value: model, sessionID: sid)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Local Persistence

    /// Save current messages to disk (debounced — only call at stable points).
    func saveHistory() {
        guard let sid = sessionID, !messages.isEmpty else { return }
        ChatHistoryStore.shared.saveMessages(messages, forSession: sid)
        if let stableID = stableSessionID(forGatewayID: sid), stableID != sid {
            ChatHistoryStore.shared.saveMessages(messages, forSession: stableID)
        }
    }

    /// Load messages from local disk for a session (instant, no network).
    @discardableResult
    func loadLocalHistory(sessionID: String) -> Bool {
        guard let cached = ChatHistoryStore.shared.loadMessages(forSession: sessionID) else {
            return false
        }
        self.messages = cached
        self.sessionID = sessionID
        self.isSessionReady = true
        self.isStreaming = false
        self.streamingMessageID = nil
        self.activeToolCalls = [:]
        self.pendingApproval = nil
        self.avatarState = .idle
        self.snapshotCurrentSession()
        return true
    }

    /// Delete local history for a session.
    func deleteLocalHistory(sessionID: String) {
        ChatHistoryStore.shared.deleteMessages(forSession: sessionID)
    }

    // MARK: - Event Handling

    private func shouldApplyEvent(sessionID eventSessionID: String?, event: GatewayEvent) -> Bool {
        switch event {
        case .gatewayReady, .backgroundComplete, .skinChanged, .voiceTranscript, .voiceStatus:
            return true
        default:
            break
        }

        guard let eventSessionID, !eventSessionID.isEmpty else {
            return true
        }
        guard let current = sessionID, !current.isEmpty else {
            return false
        }
        return eventSessionID == current
    }

    private func handleEvent(_ event: GatewayEvent, eventSessionID: String?) {
        let previousVisibleKey = visibleStateKey()
        if let eventSessionID, !eventSessionID.isEmpty {
            let key = keyForIncomingEvent(sessionID: eventSessionID)
            var state = sessionStates[key]
            if state == nil, key == previousVisibleKey {
                snapshotCurrentSession()
                state = sessionStates[key]
            }
            if state == nil, event.isLiveTurnEvent || event.isSessionScopedRequestEvent {
                let placeholder = ChatSessionState(
                    sessionID: eventSessionID,
                    messages: [],
                    isStreaming: false,
                    streamingMessageID: nil,
                    activeToolCalls: [:],
                    pendingApproval: nil,
                    avatarState: .idle,
                    error: nil,
                    sessionTitle: "New Chat",
                    currentModel: currentModel
                )
                state = placeholder
                NSLog("[HermesNative] ChatViewModel created placeholder state for session=\(eventSessionID) event=\(event.debugName)")
            }

            if var state {
                state.sessionID = eventSessionID
                applyEvent(event, to: &state)
                sessionStates[key] = state
                if !state.messages.isEmpty {
                    ChatHistoryStore.shared.saveMessages(state.messages, forSession: key)
                    if state.sessionID != key {
                        ChatHistoryStore.shared.saveMessages(state.messages, forSession: state.sessionID)
                    }
                }
                publishVisibleStateIfNeeded(for: key, previousVisibleKey: previousVisibleKey)
                return
            }

            NSLog("[HermesNative] ChatViewModel ignored event for unknown session=\(eventSessionID) event=\(event.debugName)")
            return
        }

        guard shouldApplyEvent(sessionID: eventSessionID, event: event) else {
            NSLog("[HermesNative] ChatViewModel ignored event for session=\(eventSessionID ?? "nil") current=\(sessionID ?? "nil") event=\(event.debugName)")
            return
        }

        if event.isLiveTurnEvent && !isStreaming {
            if case .messageStart = event {
                isStreaming = true
            } else {
                // A stop is optimistic: the gateway can still drain queued
                // deltas/tool/thinking events for the interrupted turn. Do not let
                // those late frames mutate avatar/tool state or resurrect UI after
                // `finishStreaming()` has cleared the local turn.
                NSLog("[HermesNative] ChatViewModel ignored late live event after stream ended: \(event.debugName)")
                return
            }
        }

        switch event {
        case .gatewayReady:
            break

        case .messageStart:
            // Streaming begins — avatar is speaking
            if streamingMessageID == nil {
                let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
                streamingMessageID = assistantMessage.id
                messages.append(assistantMessage)
            }
            avatarState = .speaking


        case .sessionInfo(let info):
            currentModel = info.model
            isSessionReady = true

        case .messageDelta(let text, _):
            // Append streaming text to the current assistant message.
            if let msgID = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content += text
            }

        case .messageComplete(payload: let payload):
            // Finalize the assistant message. If the user already hit Stop,
            // `streamingMessageID` is nil; ignore the late completion so it
            // doesn't resurrect an interrupted turn in the UI.
            guard let msgID = streamingMessageID,
                  let idx = messages.firstIndex(where: { $0.id == msgID }) else {
                activeToolCalls = [:]
                snapshotCurrentSession()
                return
            }

            messages[idx].content = payload.text
            messages[idx].isStreaming = false
            messages[idx].usage = payload.usage
            messages[idx].status = payload.status
            messages[idx].reasoning = payload.reasoning
            // Merge any accumulated tool calls into the message
            messages[idx].toolCalls = Array(activeToolCalls.values)

            activeToolCalls = [:]
            isStreaming = false
            streamingMessageID = nil
            avatarState = .idle

            // Persist to local storage after each completed response
            saveHistory()
            snapshotCurrentSession()

            // Notify if app is backgrounded or this isn't the active session
            let preview = payload.text.truncated(to: 80)
            if let sid = sessionID {
                NotificationService.shared.notifyResponseComplete(
                    sessionTitle: sessionTitle,
                    preview: preview,
                    sessionID: sid
                )
            }

        case .toolStart(payload: let payload):
            avatarState = .toolUse
            activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context
            )

        case .toolComplete(payload: let payload):
            if var record = activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            // Update matching tool call's progress display
            for (key, var record) in activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                activeToolCalls[key] = record
            }

        case .toolGenerating:
            break

        case .reasoningDelta(let text):
            // Thinking/reasoning — avatar thinks
            if avatarState != .toolUse { avatarState = .thinking }
            // Append to last assistant message's reasoning
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + text
            }

        case .thinkingDelta(let text):
            // Thinking — avatar thinks (unless tool is running)
            if avatarState != .toolUse { avatarState = .thinking }
            // Append to last assistant message's reasoning (thinking IS reasoning
            // from the model's perspective — e.g. GLM-5.1 fires thinking.delta
            // not reasoning.delta).  Show it live so the user sees progress.
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                let existing = messages[idx].reasoning ?? ""
                // Add newline between chunks if we already have content and this
                // isn't a continuation (thinking deltas from the gateway spinner
                // are discrete status messages like "🤔 pondering...")
                let separator = existing.isEmpty ? "" : "\n"
                messages[idx].reasoning = existing + separator + text
            }

        case .reasoningAvailable:
            break

        case .approvalRequest(payload: let payload):
            pendingApproval = payload
            // Push notification so user sees it even if backgrounded/on another session
            if let sid = sessionID {
                NotificationService.shared.notifyApproval(
                    sessionTitle: sessionTitle,
                    command: payload.command,
                    sessionID: sid
                )
            }

        case .statusUpdate:
            break

        case .error(let message):
            self.error = message
            isStreaming = false
            avatarState = .error

        case .skinChanged:
            break

        case .subagentSpawnRequested, .subagentStart, .subagentComplete, .subagentTool, .subagentProgress, .subagentThinking:
            // Subagent delegation events — handled by SpawnTreeStore
            break

        case .backgroundComplete(let taskID, let text):
            NotificationService.shared.notifyBackgroundComplete(taskID: taskID, text: text)

        case .clarifyRequest(let question, _):
            if let sid = sessionID {
                NotificationService.shared.notifyClarify(
                    sessionTitle: sessionTitle,
                    question: question,
                    sessionID: sid
                )
            }

        case .sudoRequest:
            // TODO: Present sudo password dialog
            break

        case .secretRequest:
            // TODO: Present secret input dialog
            break

        case .voiceTranscript, .voiceStatus:
            break
        }

        snapshotCurrentSession()
    }
}
