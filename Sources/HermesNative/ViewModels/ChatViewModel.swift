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

    private var gatewayClient: GatewayClient?
    private var sessionID: String?
    private var streamingMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var isCreatingSession = false  // Guard against double-trigger

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
                    // Auto-create session once connected
                    if self?.sessionID == nil {
                        Task {
                            await self?.createSession()
                        }
                    }
                case .error(let msg):
                    self?.error = msg
                    self?.isSessionReady = false
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
            // Streaming begins — assistant message already created in submitPrompt
            break

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

        case .toolStart(payload: let payload):
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
            // Append to last assistant message's reasoning
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[idx].reasoning = (messages[idx].reasoning ?? "") + text
            }

        case .reasoningAvailable, .thinkingDelta:
            break

        case .approvalRequest(payload: let payload):
            pendingApproval = payload

        case .statusUpdate:
            break

        case .error(let message):
            self.error = message
            isStreaming = false

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
