import Foundation
import Combine

/// Core chat ViewModel — manages conversation state and interacts with the gateway.
@MainActor
final class ChatViewModel: ObservableObject {

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
    private var streamingMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
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
        // WebSocket, so only apply events whose session_id matches this chat's
        // current session. Legacy/global events may have no session_id.
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
                    self?.isStreaming = false
                    self?.avatarState = .thinking
                case .error(let msg):
                    self?.error = msg
                    self?.isSessionReady = false
                    self?.isStreaming = false
                    self?.avatarState = .error
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
            if let resumedID = self.gatewayClient?.activeSessionID, self.sessionID != resumedID {
                self.sessionID = resumedID
                self.createGeneration += 1
                self.isSessionReady = true
                self.error = nil
            }
        }
    }

    /// The session ID currently active in this chat view.
    var currentSessionID: String? { sessionID }

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
        do {
            let sid = try await client.createSession()
            NSLog("[HermesNative] ChatViewModel createSession succeeded sid=\(sid)")
            self.sessionID = sid
            self.createGeneration += 1
            self.isSessionReady = true
            self.messages = []
            self.activeToolCalls = [:]
            self.error = nil

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
    func resumeSession(key: String) async {
        guard let client = gatewayClient else {
            self.error = "No gateway client"
            return
        }
        guard case .connected = client.connectionState else {
            self.error = "Not connected to gateway"
            return
        }
        do {
            let result = try await client.resumeSession(key: key)
            self.sessionID = result.sessionID
            self.isSessionReady = true
            self.activeToolCalls = [:]
            self.isStreaming = false
            self.avatarState = .idle
            self.error = nil

            // Parse history messages from the gateway
            self.messages = Self.parseHistoryMessages(result.messages)

            // Re-inject the app's formatting prompt on resume
            try? await client.setEphemeralPrompt(sessionID: result.sessionID, prompt: Self.appFormattingPrompt)
        } catch {
            self.error = "Session resume failed: \(error.localizedDescription)"
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
    /// Gateway format: {"role": "user"|"assistant"|"tool", "text": "...", "name": "...", "context": "..."}
    private static func parseHistoryMessages(_ rawMessages: [[String: AnyCodable]]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var currentToolCalls: [ToolCallRecord] = []

        for raw in rawMessages {
            guard let roleStr = raw["role"]?.stringValue else { continue }

            switch roleStr {
            case "user":
                let text = raw["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .user, content: text))

            case "assistant":
                // Flush any pending tool calls before this assistant message
                if !currentToolCalls.isEmpty {
                    if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                        messages[lastIdx].toolCalls = currentToolCalls
                    }
                    currentToolCalls = []
                }

                let text = raw["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .assistant, content: text, status: "complete"))

            case "tool":
                let name = raw["name"]?.stringValue ?? "tool"
                let context = raw["context"]?.stringValue
                let toolID = "hist_\(messages.count)"
                currentToolCalls.append(ToolCallRecord(
                    id: toolID,
                    name: name,
                    context: context,
                    summary: context,
                    isComplete: true
                ))

            default:
                break
            }
        }

        // Flush remaining tool calls
        if !currentToolCalls.isEmpty {
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastIdx].toolCalls = currentToolCalls
            }
        }

        return messages
    }

    // MARK: - User Input

    /// Send the current input text as a prompt.
    func submitPrompt() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = gatewayClient, let sid = sessionID else { return }

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
    }

    /// Load messages from local disk for a session (instant, no network).
    func loadLocalHistory(sessionID: String) {
        if let cached = ChatHistoryStore.shared.loadMessages(forSession: sessionID) {
            self.messages = cached
            self.sessionID = sessionID
            self.isSessionReady = true
        }
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
        guard shouldApplyEvent(sessionID: eventSessionID, event: event) else {
            let reason = "session mismatch current=\(sessionID ?? "nil")"
            NSLog("[HermesNative] ChatViewModel ignored event for session=\(eventSessionID ?? "nil") current=\(sessionID ?? "nil") event=\(event.debugName)")
            gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: reason)
            return
        }

        if event.isLiveTurnEvent && !isStreaming {
            let reason = "late live-turn event after stream ended"
            NSLog("[HermesNative] ChatViewModel ignored late live event after stream ended: \(event.debugName)")
            gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: reason)
            return
        }

        switch event {
        case .gatewayReady:
            break

        case .sessionInfo(let info):
            currentModel = info.model
            isSessionReady = true

        case .messageStart:
            // Streaming begins — avatar is speaking
            guard isStreaming else { break }
            avatarState = .speaking

        case .messageDelta(let text, _):
            // Append streaming text to the current assistant message. Ignore
            // late deltas after an interrupt; the gateway can still drain one
            // in-flight turn after the UI has already stopped it locally.
            guard isStreaming else { break }
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
            guard isStreaming else { break }
            avatarState = .toolUse
            activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context
            )

        case .toolComplete(payload: let payload):
            guard isStreaming else { break }
            if var record = activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            guard isStreaming else { break }
            // Update matching tool call's progress display
            for (key, var record) in activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                activeToolCalls[key] = record
            }

        case .toolGenerating:
            break

        case .reasoningDelta(let text):
            // Thinking/reasoning — avatar thinks
            guard isStreaming else { break }
            if avatarState != .toolUse { avatarState = .thinking }
            // Append to last assistant message's reasoning
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + text
            }

        case .thinkingDelta(let text):
            // Thinking — avatar thinks (unless tool is running)
            guard isStreaming else { break }
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
    }
}
