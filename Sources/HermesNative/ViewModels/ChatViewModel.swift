import Foundation
import Combine

/// Core chat ViewModel — manages conversation state and interacts with the gateway.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var isSessionReady: Bool = false
    @Published var currentModel: String = ""
    @Published var pendingApproval: ApprovalPayload?
    @Published var activeToolCalls: [String: ToolCallRecord] = [:] // tool_id → record
    @Published var error: String?
    @Published var avatarState: AvatarState = .idle

    private var gatewayClient: GatewayClient?
    private var sessionID: String?
    private var streamingMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var isCreatingSession = false  // Guard against double-trigger
    weak var personaManager: PersonaManager?

    // MARK: - Setup

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client

        // Subscribe to gateway events
        client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleEvent(event)
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

        // Handle reconnection — resume or create session
        client.onReconnected = { [weak self] in
            guard let self else { return }
            // Sync persona
            if let pm = self.personaManager, let client = self.gatewayClient {
                await pm.syncFromGateway(client)
            }
            // If GatewayClient already resumed the session, use that session ID
            if let resumedID = self.gatewayClient?.activeSessionID, self.sessionID != resumedID {
                self.sessionID = resumedID
                self.isSessionReady = true
                self.error = nil
            }
            // Otherwise create a new session
            if self.sessionID == nil {
                await self.createSession()
            }
        }
    }

    /// Create a new session on the gateway.
    func createSession() async {
        guard let client = gatewayClient else {
            self.error = "No gateway client"
            return
        }
        guard case .connected = client.connectionState else {
            self.error = "Not connected to gateway (state: \(client.connectionState))"
            return
        }
        guard !isCreatingSession else { return }  // Prevent double-trigger
        isCreatingSession = true
        do {
            let sid = try await client.createSession()
            self.sessionID = sid
            self.isSessionReady = true
            self.messages = []
            self.activeToolCalls = [:]
            self.error = nil
        } catch {
            self.error = "Session create failed: \(error.localizedDescription)"
        }
        isCreatingSession = false
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
            isStreaming = false
        }
    }

    /// Interrupt the current agent turn.
    func interrupt() async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        do {
            try await client.interrupt(sessionID: sid)
        } catch {
            self.error = error.localizedDescription
        }
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

    // MARK: - Event Handling

    private func handleEvent(_ event: GatewayEvent) {
        switch event {
        case .gatewayReady:
            break

        case .sessionInfo(let info):
            currentModel = info.model
            isSessionReady = true

        case .messageStart:
            // Streaming begins — avatar is speaking
            avatarState = .speaking

        case .messageDelta(let text, _):
            // Append streaming text to the current assistant message
            if let msgID = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content += text
            }

        case .messageComplete(payload: let payload):
            // Finalize the assistant message
            if let msgID = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content = payload.text
                messages[idx].isStreaming = false
                messages[idx].usage = payload.usage
                messages[idx].status = payload.status
                messages[idx].reasoning = payload.reasoning
                // Merge any accumulated tool calls into the message
                messages[idx].toolCalls = Array(activeToolCalls.values)
            }
            activeToolCalls = [:]
            isStreaming = false
            streamingMessageID = nil
            avatarState = .idle

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

        case .statusUpdate:
            break

        case .error(let message):
            self.error = message
            isStreaming = false
            avatarState = .error

        case .skinChanged:
            break

        case .subagentStart, .subagentComplete, .subagentTool:
            // Subagent delegation events — display in tool call area
            break

        case .backgroundComplete:
            // Background task completion — not displayed inline
            break

        case .clarifyRequest:
            // TODO: Present clarification dialog to user
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
}
