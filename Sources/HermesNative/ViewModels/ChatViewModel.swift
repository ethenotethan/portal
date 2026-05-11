import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ChatViewModel")

/// Core chat ViewModel — manages conversation state and interacts with the gateway.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - App Formatting Prompt
    // Injected as ephemeral system prompt so the model uses mermaid diagrams
    // and rich markdown — matching the app's native rendering capabilities.

    static let appFormattingPrompt = """
    ## Response Formatting (HermesNative App)

    You are running inside a native app that renders rich markdown and Mermaid diagrams. Use these capabilities:

    - **Mermaid diagrams** for any visual explanation. Wrap in ```mermaid blocks. One concept per diagram. Use the best type for the job:
      - `flowchart` / `graph` — processes, decision trees, architecture, data flows
      - `sequenceDiagram` — API calls, message passing, protocol exchanges, interactions between actors
      - `classDiagram` — OOP design, type hierarchies, entity relationships with attributes/methods
      - `stateDiagram-v2` — state machines, lifecycle transitions, status flows
      - `erDiagram` — database schemas, entity-relationship models, data modeling
      - `gantt` — project timelines, milestones, scheduling
      - `mindmap` — brainstorming, topic trees, concept hierarchies, org charts
      - `timeline` — chronological events, project history, release schedules
      - `pie` — proportional breakdowns, market share, distribution
      - `gitGraph` — branching strategies, release workflows, version history
      - `journey` — user journeys, experience maps, onboarding flows
      - `sankey` — resource flows, budget allocation, energy transfer
      - `quadrantChart` — priority matrices, risk/impact analysis, effort/value
      - `radar` — skill profiles, comparison across dimensions, performance metrics
      - `xychart` — trends, comparisons with axes, metrics over time
      - `treemap` — hierarchical proportions, storage breakdown, budget categories
      - `block` — block diagrams, high-level system composition
    - **Markdown headings** (##, ###) to structure longer responses
    - **Bold** for key terms, *italic* for emphasis
    - **Code blocks** with language tags (```python, ```swift, ```bash, ```sql, ```go, etc.)
    - **Ordered/unordered lists** for steps and enumerations
    - **Blockquotes** for important callouts
    - **Tables** for structured comparisons and data

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
    /// Pending media attachments for the next user message.
    @Published var pendingAttachments: [MediaAttachment] = []
    @Published var refocusInput: Int = 0

    /// Monotonic token for user-driven session switches/creates. Async resume
    /// calls must check this before committing returned history; otherwise a
    /// slower first resume can overwrite the newer selected session after rapid
    /// sidebar clicks while another turn is streaming.
    private var sessionSwitchGeneration = 0

    private struct SessionRuntimeState {
        var messages: [ChatMessage] = []
        var isStreaming: Bool = false
        var isSessionReady: Bool = false
        var pendingApproval: ApprovalPayload?
        var activeToolCalls: [String: ToolCallRecord] = [:]
        var error: String?
        var avatarState: AvatarState = .idle
        var sessionTitle: String = "New Chat"
        var streamingMessageID: UUID?
    }


    private var gatewayClient: GatewayClient?
    private var sessionID: String?
    private var stableSessionByGatewayID: [String: String] = [:]
    private var gatewayIDByStableSession: [String: String] = [:]
    private var sessionStates: [String: SessionRuntimeState] = [:]
    private var streamingMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var isCreatingSession = false  // Guard against double-trigger
    private var isStopping = false
    private var pendingVisibleEventFlush: Task<Void, Never>?
    private var pendingVisibleMessageDelta = ""
    private var pendingVisibleReasoningDelta = ""
    private var pendingVisibleThinkingDelta = ""
    private var perfEventCounts: [String: Int] = [:]
    private var perfLastLog = Date()
    private var perfFlushCount = 0
    private var perfVisibleFlushLogCount = 0
    private var perfWriteCount = 0
    private let perfLoggingEnabled = ProcessInfo.processInfo.arguments.contains("--long-session-perf")

    private var perfLogURL: URL? {
        guard perfLoggingEnabled else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("hermes-native", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("long-session-perf.log")
    }

    private func writePerfLog(_ line: String) {
        guard perfLoggingEnabled else { return }
        perfWriteCount += 1
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fullLine = "\(timestamp) #\(perfWriteCount) \(line)\n"
        log.info("\(fullLine)")
        guard let url = perfLogURL, let data = fullLine.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func writePerfSnapshot(_ label: String) {
        guard perfLoggingEnabled else { return }
        let last = messages.last
        let counts = perfEventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let fields = [
            "snapshot=\(label)",
            "session=\(sessionID ?? "nil")",
            "messages=\(messages.count)",
            "streaming=\(isStreaming)",
            "content=\(last?.content.count ?? 0)",
            "reasoning=\(last?.reasoning?.count ?? 0)",
            "activeTools=\(activeToolCalls.count)",
            "flushes=\(perfFlushCount)",
            "pendingMessageBytes=\(pendingVisibleMessageDelta.count)",
            "pendingReasoningBytes=\(pendingVisibleReasoningDelta.count)",
            "pendingThinkingBytes=\(pendingVisibleThinkingDelta.count)",
            counts,
        ]
        writePerfLog("[HermesNativePerf] \(fields.joined(separator: " "))")
    }
    weak var personaManager: PersonaManager?

    // MARK: - Setup

    func setGatewayClient(_ client: GatewayClient) {
        // ContentView can wire the same app-level client repeatedly during
        // connect/session-create flows. Avoid stacking duplicate Combine
        // subscriptions, because every gateway event would otherwise be applied
        // N times and parallel sessions quickly corrupt local chat state.
        guard gatewayClient !== client else { return }

        cancellables.removeAll()
        pendingVisibleEventFlush?.cancel()
        pendingVisibleEventFlush = nil
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
                    // Do not mark the active turn as stopped during a transient
                    // reconnect. The gateway agent may still be running, and
                    // clearing isStreaming makes later frames look stale.
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

    /// Test/debug hook for applying a gateway event exactly as the shared
    /// WebSocket subscriber would receive it.
    func receiveGatewayEventForTesting(_ event: GatewayEvent, sessionID: String?) {
        handleEvent(event, eventSessionID: sessionID)
    }

    /// Link the active short-lived gateway ID with the stable database ID shown
    /// in the sessions list. History is saved under both IDs so switching away
    /// and back does not depend on which ID is current at that exact moment.
    func bindCurrentGatewaySession(toStableSessionID stableID: String) {
        guard let runtimeID = sessionID, !stableID.isEmpty else { return }
        bindRuntimeSession(displayID: stableID, runtimeID: runtimeID)
    }

    private func displaySessionID(for runtimeID: String) -> String {
        stableSessionByGatewayID[runtimeID] ?? runtimeID
    }

    private func runtimeSessionID(for displayID: String) -> String {
        gatewayIDByStableSession[displayID] ?? displayID
    }

    /// Bind the stable database ID shown by the session list to the runtime
    /// gateway ID carried by live events. A newly-created session starts out
    /// keyed only by its short runtime ID, then `session.title` later resolves
    /// to a database ID. Without moving that cached runtime state, clicking
    /// away from a live turn and back via the database ID restores an empty
    /// history and makes the running session look like it disappeared.
    func bindRuntimeSession(displayID: String, runtimeID: String) {
        guard !displayID.isEmpty, !runtimeID.isEmpty else { return }
        stableSessionByGatewayID[runtimeID] = displayID
        gatewayIDByStableSession[displayID] = runtimeID

        if displayID != runtimeID, let runtimeState = sessionStates.removeValue(forKey: runtimeID) {
            if var displayState = sessionStates[displayID] {
                // Preserve any locally visible state that is newer/richer than
                // disk history, but prefer the live runtime stream fields.
                displayState.messages = runtimeState.messages
                displayState.isStreaming = runtimeState.isStreaming
                displayState.streamingMessageID = runtimeState.streamingMessageID
                displayState.pendingApproval = runtimeState.pendingApproval
                displayState.activeToolCalls = runtimeState.activeToolCalls
                displayState.avatarState = runtimeState.avatarState
                displayState.error = runtimeState.error
                sessionStates[displayID] = displayState
            } else {
                sessionStates[displayID] = runtimeState
            }
        }

        if sessionID == runtimeID {
            snapshotCurrentSessionState()
            if !messages.isEmpty {
                ChatHistoryStore.shared.saveMessages(messages, forSession: displayID)
            }
        }
    }

    private func snapshotCurrentSessionState() {
        guard let sessionID else { return }
        let displayID = displaySessionID(for: sessionID)
        sessionStates[displayID] = SessionRuntimeState(
            messages: messages,
            isStreaming: isStreaming,
            isSessionReady: isSessionReady,
            pendingApproval: pendingApproval,
            activeToolCalls: activeToolCalls,
            error: error,
            avatarState: avatarState,
            sessionTitle: sessionTitle,
            streamingMessageID: streamingMessageID
        )
    }

    private func restoreSessionState(displayID: String, runtimeID: String? = nil) -> Bool {
        guard let state = sessionStates[displayID] else { return false }
        sessionID = runtimeID ?? runtimeSessionID(for: displayID)
        messages = state.messages
        isStreaming = state.isStreaming
        isSessionReady = state.isSessionReady
        pendingApproval = state.pendingApproval
        activeToolCalls = state.activeToolCalls
        error = state.error
        avatarState = state.avatarState
        sessionTitle = state.sessionTitle
        streamingMessageID = state.streamingMessageID
        return true
    }

    private func mutateSessionState(for eventSessionID: String, _ mutation: (inout SessionRuntimeState) -> Void) {
        let displayID = displaySessionID(for: eventSessionID)
        var state = sessionStates[displayID] ?? SessionRuntimeState()
        mutation(&state)
        sessionStates[displayID] = state
        if sessionID == eventSessionID || displaySessionID(for: sessionID ?? "") == displayID {
            _ = restoreSessionState(displayID: displayID, runtimeID: eventSessionID)
        }
    }

    /// Create a new session on the gateway.
    func createSession() async {
        guard let client = gatewayClient else {
            self.error = "No gateway client"
            return
        }
        log.info("ChatViewModel createSession invoked state=\(String(describing: client.connectionState))")
        guard !isCreatingSession else {
            log.info("ChatViewModel createSession ignored: already creating")
            return
        }
        isCreatingSession = true
        do {
            let sid = try await client.createSession()
            log.info("ChatViewModel createSession succeeded sid=\(sid)")
            snapshotCurrentSessionState()
            self.sessionID = sid
            self.createGeneration += 1
            self.isSessionReady = true
            self.messages = []
            self.activeToolCalls = [:]
            self.pendingApproval = nil
            self.streamingMessageID = nil
            self.isStreaming = false
            self.avatarState = .idle
            self.error = nil
            snapshotCurrentSessionState()

            await applyEphemeralPrompt(for: sid, using: client)
        } catch {
            self.error = "Session create failed: \(error.localizedDescription)"
        }
        isCreatingSession = false
    }

    /// Starts a user-visible switch immediately from local cache and returns a
    /// generation token. Call `resumeSession(key:generation:)` to revalidate the
    /// same selection from the gateway; stale generations are ignored.
    @discardableResult
    func beginSwitchToSession(key: String) -> Int {
        snapshotCurrentSessionState()
        sessionSwitchGeneration += 1
        let generation = sessionSwitchGeneration

        if restoreSessionState(displayID: key) {
            return generation
        }
        if let cachedMessages = ChatHistoryStore.shared.loadMessages(forSession: key) {
            self.messages = cachedMessages
            self.sessionID = runtimeSessionID(for: key)
            self.isSessionReady = true
            self.isStreaming = false
            self.streamingMessageID = nil
            self.activeToolCalls = [:]
            self.pendingApproval = nil
            self.avatarState = .idle
            self.error = nil
            snapshotCurrentSessionState()
            return generation
        }

        // Bind the selected session immediately, even before session.resume
        // returns, so the previous streaming chat cannot keep owning the detail
        // pane/composer during rapid sidebar clicks.
        self.sessionID = runtimeSessionID(for: key)
        self.messages = []
        self.isSessionReady = true
        self.isStreaming = false
        self.streamingMessageID = nil
        self.activeToolCalls = [:]
        self.pendingApproval = nil
        self.avatarState = .idle
        self.error = nil
        self.sessionTitle = "New Chat"
        snapshotCurrentSessionState()
        return generation
    }

    /// Resume an existing session by key, replacing the currently visible chat state.
    /// Existing live state for the previously selected session is snapshotted first,
    /// so switching away from an active reasoning/tool turn does not discard it.
    @discardableResult
    func resumeSession(key: String) async -> Bool {
        let generation = beginSwitchToSession(key: key)
        return await resumeSession(key: key, generation: generation)
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

        let cachedBeforeResume = sessionStates[key]

        do {
            let result = try await client.resumeSession(key: key)
            guard generation == sessionSwitchGeneration else {
                log.info("ignoring stale resume for \(key) generation=\(generation) current=\(self.sessionSwitchGeneration)")
                return false
            }

            stableSessionByGatewayID[result.sessionID] = key
            gatewayIDByStableSession[key] = result.sessionID

            let parsedMessages = Self.parseHistoryMessages(result.messages)
            if !parsedMessages.isEmpty {
                if var liveState = sessionStates[key], liveState.isStreaming {
                    // The gateway history returned by session.resume is a persisted
                    // snapshot and can lag behind the currently running turn. Do not
                    // replace an in-memory live stream with non-streaming history when
                    // the user clicks away and back mid-tool-use; that is the exact
                    // path that made the live session appear to disappear.
                    if liveState.messages.isEmpty {
                        liveState.messages = parsedMessages
                    }
                    liveState.isSessionReady = true
                    sessionStates[key] = liveState
                } else {
                    sessionStates[key] = SessionRuntimeState(
                        messages: parsedMessages,
                        isStreaming: false,
                        isSessionReady: true,
                        sessionTitle: cachedBeforeResume?.sessionTitle ?? sessionTitle
                    )
                }
            } else if cachedBeforeResume == nil, let cachedMessages = ChatHistoryStore.shared.loadMessages(forSession: key) {
                sessionStates[key] = SessionRuntimeState(
                    messages: cachedMessages,
                    isStreaming: false,
                    isSessionReady: true
                )
            }

            if !restoreSessionState(displayID: key, runtimeID: result.sessionID) {
                self.sessionID = result.sessionID
                self.isSessionReady = true
                self.messages = []
                self.activeToolCalls = [:]
                self.pendingApproval = nil
                self.isStreaming = false
                self.streamingMessageID = nil
                self.avatarState = .idle
                self.error = nil
                snapshotCurrentSessionState()
            }

            await applyEphemeralPrompt(for: result.sessionID, using: client)
            return true
        } catch {
            if generation == sessionSwitchGeneration {
                self.error = "Session resume failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func applyEphemeralPrompt(for sessionID: String, using client: GatewayClient) async {
        var prompt = Self.appFormattingPrompt
        if let personaManager,
           !personaManager.usesAgentDefault,
           let personaSuffix = personaManager.activePersona.systemPromptSuffix,
           !personaSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + personaSuffix
        }
        try? await client.setEphemeralPrompt(sessionID: sessionID, prompt: prompt)
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

    // MARK: Media Attachments

    /// Add an image file to pending attachments for the next message.
    func addAttachment(path: String) {
        let thumbnail = MediaAttachment.generateThumbnail(for: path)
        let attachment = MediaAttachment(path: path, thumbnailData: thumbnail)
        pendingAttachments.append(attachment)
    }

    /// Remove a pending attachment.
    func removeAttachment(_ attachment: MediaAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Remove all pending attachments.
    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    /// Send the current input text as a prompt.
    func submitPrompt() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        // Allow submit if there is text OR pending attachments
        guard (!text.isEmpty || !attachments.isEmpty),
              let client = gatewayClient, let sid = sessionID else { return }
        guard !isStreaming && !isStopping else {
            log.info("ChatViewModel submitPrompt ignored while streaming/stopping")
            return
        }

        inputText = ""
        pendingAttachments = []
        isStreaming = true

        // Add user message to conversation (with attachments)
        let userMessage = ChatMessage(
            role: .user,
            content: text,
            userAttachments: attachments
        )
        messages.append(userMessage)

        // Auto-title from first user message
        if messages.filter({ $0.role == .user }).count == 1 {
            sessionTitle = text.isEmpty
                ? "Image chat"
                : String(text.prefix(60))
        }

        // Persist user message immediately
        saveHistory()
        snapshotCurrentSessionState()

        // Prepare streaming assistant message
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        )
        streamingMessageID = assistantMessage.id
        messages.append(assistantMessage)
        snapshotCurrentSessionState()

        do {
            // Attach images via image.attach RPC BEFORE prompt.submit.
            // The gateway requires images to be pre-registered.
            for attachment in attachments {
                try await client.attachImage(path: attachment.path, sessionID: sid)
            }
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

    private var saveHistoryTask: Task<Void, Never>?

    /// Save current messages to disk immediately.
    func saveHistory() {
        guard let sid = sessionID, !messages.isEmpty else { return }
        ChatHistoryStore.shared.saveMessages(messages, forSession: sid)
        let displayID = displaySessionID(for: sid)
        if displayID != sid {
            ChatHistoryStore.shared.saveMessages(messages, forSession: displayID)
        }
    }

    /// Debounced save — coalesces rapid calls during streaming into at most one save per second.
    func saveHistoryDebounced() {
        saveHistoryTask?.cancel()
        saveHistoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveHistory()
        }
    }

    /// Load messages from local disk for a session (instant, no network).
    func loadLocalHistory(sessionID: String) {
        snapshotCurrentSessionState()
        if restoreSessionState(displayID: sessionID) {
            return
        }
        if let cached = ChatHistoryStore.shared.loadMessages(forSession: sessionID) {
            self.messages = cached
            self.sessionID = runtimeSessionID(for: sessionID)
            self.isSessionReady = true
            self.isStreaming = false
            self.streamingMessageID = nil
            self.activeToolCalls = [:]
            snapshotCurrentSessionState()
        }
    }

    /// Delete local history for a session.
    func deleteLocalHistory(sessionID: String) {
        ChatHistoryStore.shared.deleteMessages(forSession: sessionID)
        sessionStates.removeValue(forKey: sessionID)
    }

#if DEBUG
    @discardableResult
    func createLocalTestSession(id: String) -> String {
        snapshotCurrentSessionState()
        sessionID = id
        messages = []
        isStreaming = false
        isSessionReady = true
        pendingApproval = nil
        activeToolCalls = [:]
        error = nil
        avatarState = .idle
        sessionTitle = "New Chat"
        streamingMessageID = nil
        snapshotCurrentSessionState()
        return id
    }

    func switchToLocalTestSession(id: String) {
        snapshotCurrentSessionState()
        _ = restoreSessionState(displayID: id, runtimeID: runtimeSessionID(for: id))
    }

    var testCachedMessageCount: Int {
        guard let sessionID else { return 0 }
        return sessionStates[displaySessionID(for: sessionID)]?.messages.count ?? 0
    }

    func simulateTestResumeResult(displayID: String, runtimeID: String, history: [ChatMessage]) {
        stableSessionByGatewayID[runtimeID] = displayID
        gatewayIDByStableSession[displayID] = runtimeID
        if var liveState = sessionStates[displayID], liveState.isStreaming {
            if liveState.messages.isEmpty {
                liveState.messages = history
            }
            liveState.isSessionReady = true
            sessionStates[displayID] = liveState
        } else {
            sessionStates[displayID] = SessionRuntimeState(
                messages: history,
                isStreaming: false,
                isSessionReady: true
            )
        }
        _ = restoreSessionState(displayID: displayID, runtimeID: runtimeID)
    }

    func applyTestEvent(_ event: GatewayEvent, sessionID: String) {
        applySessionEvent(event, to: sessionID)
    }
#endif


    private func appendThinkingTrace(_ text: String, kind: ThinkingBlock.Kind, to message: inout ChatMessage) {
        if message.thinkingTrace == nil {
            message.thinkingTrace = ThinkingTrace(isStreaming: message.isStreaming)
        }
        message.thinkingTrace?.append(text, kind: kind)
    }

    private func finishThinkingTrace(on message: inout ChatMessage, finalReasoning: String?) {
        if let finalReasoning, !finalReasoning.isEmpty, message.thinkingTrace == nil {
            message.thinkingTrace = ThinkingTrace(
                blocks: [ThinkingBlock(kind: .reasoning, text: finalReasoning)],
                isStreaming: false
            )
        }
        message.thinkingTrace?.finish()
        // Keep the legacy reasoning field populated for persistence/search and
        // backward-compatible views, but the UI prefers the structured trace.
        if let traceText = message.thinkingTrace?.fullText, !traceText.isEmpty {
            message.reasoning = traceText
        } else {
            message.reasoning = finalReasoning
        }
    }

    // MARK: - Event Handling

    private func shouldApplyGlobalEvent(_ event: GatewayEvent) -> Bool {
        switch event {
        case .gatewayReady, .backgroundComplete, .skinChanged, .voiceTranscript, .voiceStatus:
            return true
        default:
            return false
        }
    }

    private func recordPerfEvent(_ name: String, bytes: Int = 0) {
        guard perfLoggingEnabled else { return }
        perfEventCounts[name, default: 0] += 1
        if bytes > 0 { perfEventCounts["\(name).bytes", default: 0] += bytes }
        let now = Date()
        guard now.timeIntervalSince(perfLastLog) >= 5 else { return }
        perfLastLog = now
        let counts = perfEventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let fields = [
            "visible",
            "session=\(sessionID ?? "nil")",
            "messages=\(messages.count)",
            "streaming=\(isStreaming)",
            "content=\(messages.last?.content.count ?? 0)",
            "reasoning=\(messages.last?.reasoning?.count ?? 0)",
            "activeTools=\(activeToolCalls.count)",
            "flushes=\(perfFlushCount)",
            counts,
        ]
        writePerfLog("[HermesNativePerf] \(fields.joined(separator: " "))")
    }

    private func appendPendingVisibleMessageDelta(_ text: String) {
        recordPerfEvent("messageDelta", bytes: text.count)
        pendingVisibleMessageDelta += text
        scheduleVisibleEventFlush()
    }

    private func appendPendingVisibleReasoningDelta(_ text: String, separator: String = "") {
        recordPerfEvent("reasoningDelta", bytes: text.count)
        if !pendingVisibleReasoningDelta.isEmpty || !pendingVisibleThinkingDelta.isEmpty {
            pendingVisibleReasoningDelta += separator
        }
        pendingVisibleReasoningDelta += text
        scheduleVisibleEventFlush()
    }

    private func appendPendingVisibleThinkingDelta(_ text: String, separator: String = "") {
        recordPerfEvent("thinkingDelta", bytes: text.count)
        if !pendingVisibleThinkingDelta.isEmpty || !pendingVisibleReasoningDelta.isEmpty {
            pendingVisibleThinkingDelta += separator
        }
        pendingVisibleThinkingDelta += text
        scheduleVisibleEventFlush()
    }

    private func scheduleVisibleEventFlush() {
        guard pendingVisibleEventFlush == nil else { return }
        pendingVisibleEventFlush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            flushPendingVisibleEventDeltas()
        }
    }

    private func flushPendingVisibleEventDeltas() {
        pendingVisibleEventFlush = nil
        let messageDelta = pendingVisibleMessageDelta
        let reasoningDelta = pendingVisibleReasoningDelta
        let thinkingDelta = pendingVisibleThinkingDelta
        pendingVisibleMessageDelta = ""
        pendingVisibleReasoningDelta = ""
        pendingVisibleThinkingDelta = ""

        guard !messageDelta.isEmpty || !reasoningDelta.isEmpty || !thinkingDelta.isEmpty else { return }
        perfFlushCount += 1
        recordPerfEvent("visibleFlush")
        if perfLoggingEnabled {
            perfVisibleFlushLogCount += 1
            if perfVisibleFlushLogCount <= 20 || perfVisibleFlushLogCount % 20 == 0 {
                writePerfLog("[HermesNativePerf] flush=\(perfVisibleFlushLogCount) " +
                    "messageBytes=\(messageDelta.count) " +
                    "reasoningBytes=\(reasoningDelta.count) " +
                    "thinkingBytes=\(thinkingDelta.count) " +
                    "pendingMessages=\(messages.count)")
            }
        }

        // Update the streaming message in-place instead of replacing the
        // entire messages array.  This avoids a full SwiftUI re-render of
        // every message view on each 500ms flush tick.
        if !messageDelta.isEmpty {
            if let msgID = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content += messageDelta
            } else if isStreaming, let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[idx].content += messageDelta
            }
        }
        if !reasoningDelta.isEmpty {
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                let existing = messages[idx].reasoning ?? ""
                messages[idx].reasoning = existing + reasoningDelta
            }
        }
        if !thinkingDelta.isEmpty {
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                let existing = messages[idx].reasoning ?? ""
                messages[idx].reasoning = existing + thinkingDelta
            }
        }
        snapshotCurrentSessionState()
    }

    private func applySessionEvent(_ event: GatewayEvent, to eventSessionID: String) {
        let displayID = displaySessionID(for: eventSessionID)
        var state = sessionStates[displayID] ?? SessionRuntimeState()

        if event.isLiveTurnEvent && !state.isStreaming {
            switch event {
            case .messageStart:
                break
            default:
                let reason = "late live-turn event after stream ended"
                log.info("ChatViewModel ignored late live event after stream ended: \(event.debugName)")
                gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: reason)
                return
            }
        }

        switch event {
        case .sessionInfo(let info):
            currentModel = info.model
            state.isSessionReady = true

        case .messageStart:
            state.isStreaming = true
            state.avatarState = .speaking
            if state.streamingMessageID == nil {
                let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
                state.streamingMessageID = assistantMessage.id
                state.messages.append(assistantMessage)
            }
            if displaySessionID(for: sessionID ?? "") == displayID {
                streamingMessageID = state.streamingMessageID
            }
            if let sid = sessionID ?? currentSessionID {
                SessionRunHistoryStore.shared.recordRunStart(sessionID: sid)
            }

        case .messageDelta(let text, _):
            if let msgID = state.streamingMessageID,
               let idx = state.messages.firstIndex(where: { $0.id == msgID }) {
                state.messages[idx].content += text
                if displaySessionID(for: sessionID ?? "") == displayID {
                    recordPerfEvent("sessionMessageDelta", bytes: text.count)
                    pendingVisibleMessageDelta += text
                    scheduleVisibleEventFlush()
                }
            }

        case .messageComplete(payload: let payload):
            if displaySessionID(for: sessionID ?? "") == displayID {
                flushPendingVisibleEventDeltas()
            }
            guard let msgID = state.streamingMessageID,
                  let idx = state.messages.firstIndex(where: { $0.id == msgID }) else {
                state.activeToolCalls = [:]
                break
            }
            state.messages[idx].content = payload.text
            state.messages[idx].isStreaming = false
            state.messages[idx].usage = payload.usage
            state.messages[idx].status = payload.status
            finishThinkingTrace(on: &state.messages[idx], finalReasoning: payload.reasoning)
            state.messages[idx].toolCalls = Array(state.activeToolCalls.values)
            state.activeToolCalls = [:]
            state.isStreaming = false
            state.streamingMessageID = nil
            state.avatarState = .idle
            if let sid = sessionID ?? currentSessionID {
                let runStatus: SessionRunEvent.RunStatus = payload.status == "error" ? .failed : .completed
                SessionRunHistoryStore.shared.recordRunEnd(
                    sessionID: sid,
                    inputTokens: payload.usage?.promptTokens ?? 0,
                    outputTokens: payload.usage?.completionTokens ?? 0,
                    totalTokens: payload.usage?.totalTokens ?? 0,
                    apiCalls: 1,
                    status: runStatus
                )
            }

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
            if state.avatarState != .toolUse && state.avatarState != .thinking { state.avatarState = .thinking }
            if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                state.messages[idx].reasoning = (state.messages[idx].reasoning ?? "") + text
                if displaySessionID(for: sessionID ?? "") == displayID {
                    pendingVisibleReasoningDelta += text
                    scheduleVisibleEventFlush()
                }
            }

        case .thinkingDelta(let text):
            if state.avatarState != .toolUse && state.avatarState != .thinking { state.avatarState = .thinking }
            if displaySessionID(for: sessionID ?? "") == displayID {
                let existing = messages.last(where: { $0.role == .assistant && $0.isStreaming })?.reasoning ?? ""
                let separator = existing.isEmpty ? "" : "\n"
                appendPendingVisibleThinkingDelta(text, separator: separator)
            } else if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
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

        case .statusUpdate, .toolGenerating, .reasoningAvailable,
             .gatewayReady, .skinChanged, .backgroundComplete,
             .clarifyRequest, .sudoRequest, .secretRequest,
             .voiceTranscript, .voiceStatus,
             .activityCreated, .activityUpdated,
             .subagentSpawnRequested, .subagentStart, .subagentComplete,
             .subagentTool, .subagentProgress, .subagentThinking:
            break
        }

        sessionStates[displayID] = state
        let isVisibleCoalescedDelta: Bool
        switch event {
        case .messageDelta, .reasoningDelta, .thinkingDelta:
            isVisibleCoalescedDelta = displaySessionID(for: sessionID ?? "") == displayID
        default:
            isVisibleCoalescedDelta = false
        }
        if displaySessionID(for: sessionID ?? "") == displayID {
            if isVisibleCoalescedDelta {
                // Coalesced delta events are published on a 500ms cadence via
                // scheduleVisibleEventFlush() — do NOT publish immediately here
                // or every token triggers a full SwiftUI re-render cycle.
            } else {
                _ = restoreSessionState(displayID: displayID, runtimeID: eventSessionID)
            }
        }

        if case .messageComplete(let payload) = event {
            saveHistoryDebounced()
            #if !DEBUG
            NotificationService.shared.notifyResponseComplete(
                sessionTitle: state.sessionTitle,
                preview: payload.text.truncated(to: 80),
                sessionID: eventSessionID
            )
            #endif
        }
    }

    private func handleEvent(_ event: GatewayEvent, eventSessionID: String?) {
        if let eventSessionID, !eventSessionID.isEmpty {
            applySessionEvent(event, to: eventSessionID)
            return
        }

        guard shouldApplyGlobalEvent(event) || sessionID != nil else {
            log.info("ChatViewModel ignored global event current=\(self.sessionID ?? "nil") event=\(event.debugName)")
            gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: "no active session")
            return
        }

        switch event {
        case .gatewayReady, .activityCreated, .activityUpdated:
            break

        case .sessionInfo(let info):
            currentModel = info.model
            isSessionReady = true

        case .messageStart:
            // Streaming begins — avatar is speaking
            guard isStreaming else { break }
            avatarState = .speaking

        case .messageDelta(let text, _):
            recordPerfEvent("messageDelta", bytes: text.count)
            // Append streaming text to the current assistant message. Ignore
            // late deltas after an interrupt; the gateway can still drain one
            // in-flight turn after the UI has already stopped it locally.
            guard isStreaming else { break }
            appendPendingVisibleMessageDelta(text)

        case .messageComplete(payload: let payload):
            flushPendingVisibleEventDeltas()
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
            finishThinkingTrace(on: &messages[idx], finalReasoning: payload.reasoning)
            // Merge any accumulated tool calls into the message
            messages[idx].toolCalls = Array(activeToolCalls.values)

            activeToolCalls = [:]
            isStreaming = false
            streamingMessageID = nil
            avatarState = .idle

            writePerfSnapshot("messageComplete")

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
            recordPerfEvent("toolStart")
            guard isStreaming else { break }
            avatarState = .toolUse
            activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context
            )

        case .toolComplete(payload: let payload):
            recordPerfEvent("toolComplete")
            guard isStreaming else { break }
            if var record = activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            recordPerfEvent("toolProgress", bytes: preview.count)
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
            if avatarState != .toolUse && avatarState != .thinking { avatarState = .thinking }
            appendPendingVisibleReasoningDelta(text)

        case .thinkingDelta(let text):
            guard isStreaming else { break }
            if avatarState != .toolUse && avatarState != .thinking { avatarState = .thinking }
            // Append to last assistant message's reasoning (thinking IS reasoning
            // from the model's perspective — e.g. GLM-5.1 fires thinking.delta
            // not reasoning.delta).  Show it live so the user sees progress.
            let separator: String
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }),
               messages[idx].reasoning?.isEmpty == false {
                separator = "\n"
            } else {
                separator = ""
            }
            appendPendingVisibleThinkingDelta(text, separator: separator)

        case .reasoningAvailable:
            break

        case .approvalRequest(payload: let payload):
            pendingApproval = payload

        case .statusUpdate:
            break

        case .error(let message):
            self.error = message
            isStreaming = false
            avatarState = .error
            writePerfSnapshot("error")

        case .skinChanged:
            break

        case .subagentSpawnRequested, .subagentStart, .subagentComplete, .subagentTool, .subagentProgress, .subagentThinking:
            // Subagent delegation events — handled by SpawnTreeStore
            break

        case .backgroundComplete(let taskID, let text):
            break

        case .clarifyRequest:
            break

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

    private func notifyResponseCompleteIfNeeded(payload: MessageCompletePayload, eventSessionID: String?) {
        guard payload.status == "complete" else { return }
        let sid = eventSessionID ?? sessionID
        guard let sid, !sid.isEmpty else { return }

        let title: String
        if sid == sessionID {
            title = sessionTitle.isEmpty ? "Response complete" : sessionTitle
        } else {
            title = "Session \(sid.prefix(8))"
        }

        let preview = payload.text.isEmpty ? "Response complete" : payload.text.truncated(to: 80)
        NotificationService.shared.notifyResponseComplete(
            sessionTitle: title,
            preview: preview,
            sessionID: sid
        )
    }
}
