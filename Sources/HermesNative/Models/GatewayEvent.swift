import Foundation

/// Typed representation of all gateway event types the server can emit.
/// Each case carries a strongly-typed payload where possible.
///
/// Source: tui_gateway/server.py _emit() calls
enum GatewayEvent {
    var debugName: String {
        switch self {
        case .gatewayReady: "gateway.ready"
        case .sessionInfo: "session.info"
        case .messageStart: "message.start"
        case .messageDelta: "message.delta"
        case .messageComplete: "message.complete"
        case .toolStart: "tool.start"
        case .toolComplete: "tool.complete"
        case .toolProgress: "tool.progress"
        case .toolGenerating: "tool.generating"
        case .reasoningDelta: "reasoning.delta"
        case .reasoningAvailable: "reasoning.available"
        case .thinkingDelta: "thinking.delta"
        case .subagentSpawnRequested: "subagent.spawn_requested"
        case .subagentStart: "subagent.start"
        case .subagentComplete: "subagent.complete"
        case .subagentTool: "subagent.tool"
        case .subagentProgress: "subagent.progress"
        case .subagentThinking: "subagent.thinking"
        case .backgroundComplete: "background.complete"
        case .approvalRequest: "approval.request"
        case .clarifyRequest: "clarify.request"
        case .sudoRequest: "sudo.request"
        case .secretRequest: "secret.request"
        case .statusUpdate: "status.update"
        case .error: "error"
        case .skinChanged: "skin.changed"
        case .voiceTranscript: "voice.transcript"
        case .voiceStatus: "voice.status"
        }
    }

    var isLiveTurnEvent: Bool {
        switch self {
        case .messageStart,
             .messageDelta,
             .messageComplete,
             .toolStart,
             .toolComplete,
             .toolProgress,
             .toolGenerating,
             .reasoningDelta,
             .reasoningAvailable,
             .thinkingDelta:
            return true
        default:
            return false
        }
    }

    // Connection lifecycle
    case gatewayReady(skin: String)

    // Session
    case sessionInfo(SessionInfo)

    // Chat streaming
    case messageStart
    case messageDelta(text: String, rendered: String?)
    case messageComplete(payload: MessageCompletePayload)

    // Tool calls
    case toolStart(payload: ToolStartPayload)
    case toolComplete(payload: ToolCompletePayload)
    case toolProgress(name: String, preview: String)
    case toolGenerating(name: String)

    // Reasoning / thinking
    case reasoningDelta(text: String)
    case reasoningAvailable(text: String)
    case thinkingDelta(text: String)

    // Subagent delegation
    case subagentSpawnRequested(payload: SubagentPayload)
    case subagentStart(payload: SubagentPayload)
    case subagentComplete(payload: SubagentCompletePayload)
    case subagentTool(payload: SubagentToolPayload)
    case subagentProgress(text: String)
    case subagentThinking(text: String)

    // Background tasks
    case backgroundComplete(taskID: String, text: String)

    // Approvals / blocking requests
    case approvalRequest(payload: ApprovalPayload)
    case clarifyRequest(question: String, choices: [String])
    case sudoRequest
    case secretRequest(prompt: String, envVar: String)

    // Status
    case statusUpdate(kind: String, text: String)
    case error(message: String)

    // Skin
    case skinChanged(skin: String?)

    // Voice
    case voiceTranscript(text: String, noSpeechLimit: Bool)
    case voiceStatus(state: String)

    /// Parse from raw JSON-RPC event params.
    static func from(type: String, payload: AnyCodable?) -> GatewayEvent {
        let p = payload?.dictionaryValue ?? [:]

        switch type {
        case "gateway.ready":
            let skin = p["skin"]?.stringValue ?? ""
            return .gatewayReady(skin: skin)

        case "session.info":
            return .sessionInfo(SessionInfo.from(p))

        case "message.start":
            return .messageStart

        case "message.delta":
            return .messageDelta(
                text: p["text"]?.stringValue ?? "",
                rendered: p["rendered"]?.stringValue
            )

        case "message.complete":
            return .messageComplete(payload: MessageCompletePayload.from(p))

        case "tool.start":
            return .toolStart(payload: ToolStartPayload.from(p))

        case "tool.complete":
            return .toolComplete(payload: ToolCompletePayload.from(p))

        case "tool.progress":
            return .toolProgress(
                name: p["name"]?.stringValue ?? "",
                preview: p["preview"]?.stringValue ?? ""
            )

        case "tool.generating":
            return .toolGenerating(name: p["name"]?.stringValue ?? "")

        case "reasoning.delta":
            return .reasoningDelta(text: p["text"]?.stringValue ?? "")

        case "reasoning.available":
            return .reasoningAvailable(text: p["text"]?.stringValue ?? "")

        case "thinking.delta":
            return .thinkingDelta(text: p["text"]?.stringValue ?? "")

        case "subagent.spawn_requested":
            return .subagentSpawnRequested(payload: SubagentPayload.from(p))

        case "subagent.start":
            return .subagentStart(payload: SubagentPayload.from(p))

        case "subagent.complete":
            return .subagentComplete(payload: SubagentCompletePayload.from(p))

        case "subagent.tool":
            return .subagentTool(payload: SubagentToolPayload.from(p))

        case "subagent.progress":
            return .subagentProgress(text: p["text"]?.stringValue ?? "")

        case "subagent.thinking":
            return .subagentThinking(text: p["text"]?.stringValue ?? "")

        case "background.complete":
            return .backgroundComplete(
                taskID: p["task_id"]?.stringValue ?? "",
                text: p["text"]?.stringValue ?? ""
            )

        case "approval.request":
            return .approvalRequest(payload: ApprovalPayload.from(p))

        case "clarify.request":
            let choices = p["choices"]?.arrayValue?.map { $0.stringValue ?? "" } ?? []
            return .clarifyRequest(
                question: p["question"]?.stringValue ?? "",
                choices: choices
            )

        case "sudo.request":
            return .sudoRequest

        case "secret.request":
            return .secretRequest(
                prompt: p["prompt"]?.stringValue ?? "",
                envVar: p["env_var"]?.stringValue ?? ""
            )

        case "status.update":
            return .statusUpdate(
                kind: p["kind"]?.stringValue ?? "status",
                text: p["text"]?.stringValue ?? ""
            )

        case "error":
            return .error(message: p["message"]?.stringValue ?? "unknown error")

        case "skin.changed":
            return .skinChanged(skin: p["skin"]?.stringValue)

        case "voice.transcript":
            return .voiceTranscript(
                text: p["text"]?.stringValue ?? "",
                noSpeechLimit: p["no_speech_limit"]?.boolValue ?? false
            )

        case "voice.status":
            return .voiceStatus(state: p["state"]?.stringValue ?? "")

        default:
            return .error(message: "unknown event type: \(type)")
        }
    }
}

// MARK: - Payload Types

struct SessionInfo {
    let model: String
    let reasoningEffort: String
    let fast: Bool
    let tools: [String: [String]]
    let skills: [String: String]
    let cwd: String
    let version: String
    let usage: UsageInfo?
    let mcpServers: [MCPServerInfo]?

    static func from(_ p: [String: AnyCodable]) -> SessionInfo {
        var tools: [String: [String]] = [:]
        if let toolsDict = p["tools"]?.dictionaryValue {
            for (key, value) in toolsDict {
                tools[key] = value.arrayValue?.map { $0.stringValue ?? "" } ?? []
            }
        }

        var skills: [String: String] = [:]
        if let skillsDict = p["skills"]?.dictionaryValue {
            for (key, value) in skillsDict {
                skills[key] = value.stringValue ?? ""
            }
        }

        return SessionInfo(
            model: p["model"]?.stringValue ?? "",
            reasoningEffort: p["reasoning_effort"]?.stringValue ?? "",
            fast: p["fast"]?.boolValue ?? false,
            tools: tools,
            skills: skills,
            cwd: p["cwd"]?.stringValue ?? "",
            version: p["version"]?.stringValue ?? "",
            usage: p["usage"].flatMap { UsageInfo.from($0) },
            mcpServers: nil
        )
    }
}

struct UsageInfo: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    static func from(_ v: AnyCodable) -> UsageInfo? {
        guard let d = v.dictionaryValue else { return nil }
        return UsageInfo(
            promptTokens: d["prompt_tokens"]?.intValue ?? 0,
            completionTokens: d["completion_tokens"]?.intValue ?? 0,
            totalTokens: d["total_tokens"]?.intValue ?? 0
        )
    }
}

struct MCPServerInfo {
    let name: String
    let status: String
}

struct MessageCompletePayload {
    let text: String
    let status: String // "complete", "interrupted", "error"
    let usage: UsageInfo?
    let reasoning: String?
    let rendered: String?
    let warning: String?

    static func from(_ p: [String: AnyCodable]) -> MessageCompletePayload {
        MessageCompletePayload(
            text: p["text"]?.stringValue ?? "",
            status: p["status"]?.stringValue ?? "complete",
            usage: p["usage"].flatMap { UsageInfo.from($0) },
            reasoning: p["reasoning"]?.stringValue,
            rendered: p["rendered"]?.stringValue,
            warning: p["warning"]?.stringValue
        )
    }
}

struct ToolStartPayload {
    let toolID: String
    let name: String
    let context: String

    static func from(_ p: [String: AnyCodable]) -> ToolStartPayload {
        ToolStartPayload(
            toolID: p["tool_id"]?.stringValue ?? "",
            name: p["name"]?.stringValue ?? "",
            context: p["context"]?.stringValue ?? ""
        )
    }
}

struct ToolCompletePayload {
    let toolID: String
    let name: String
    let summary: String?
    let durationSeconds: Double?
    let inlineDiff: String?
    let todos: [TodoItem]?

    static func from(_ p: [String: AnyCodable]) -> ToolCompletePayload {
        var todos: [TodoItem]?
        if let todoArray = p["todos"]?.arrayValue {
            todos = todoArray.compactMap { item -> TodoItem? in
                guard let d = item.dictionaryValue else { return nil }
                return TodoItem(
                    id: d["id"]?.stringValue ?? "",
                    content: d["content"]?.stringValue ?? "",
                    status: d["status"]?.stringValue ?? "pending"
                )
            }
        }

        return ToolCompletePayload(
            toolID: p["tool_id"]?.stringValue ?? "",
            name: p["name"]?.stringValue ?? "",
            summary: p["summary"]?.stringValue,
            durationSeconds: p["duration_seconds"]?.doubleValue,
            inlineDiff: p["inline_diff"]?.stringValue,
            todos: todos
        )
    }
}

struct TodoItem {
    let id: String
    let content: String
    let status: String
}

struct ApprovalPayload {
    let command: String
    let sessionKey: String
    let toolName: String?
    let rawArgs: String?

    static func from(_ p: [String: AnyCodable]) -> ApprovalPayload {
        ApprovalPayload(
            command: p["command"]?.stringValue ?? "",
            sessionKey: p["session_key"]?.stringValue ?? "",
            toolName: p["tool_name"]?.stringValue,
            rawArgs: p["raw_args"]?.stringValue
        )
    }
}

struct SubagentPayload {
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let subagentID: String?
    let parentID: String?
    let depth: Int?
    let model: String?

    static func from(_ p: [String: AnyCodable]) -> SubagentPayload {
        SubagentPayload(
            goal: p["goal"]?.stringValue ?? "",
            taskCount: p["task_count"]?.intValue ?? 1,
            taskIndex: p["task_index"]?.intValue ?? 0,
            subagentID: p["subagent_id"]?.stringValue,
            parentID: p["parent_id"]?.stringValue,
            depth: p["depth"]?.intValue,
            model: p["model"]?.stringValue
        )
    }
}

struct SubagentCompletePayload {
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let subagentID: String?
    let parentID: String?
    let depth: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let apiCalls: Int?
    let costUSD: Double?
    let filesRead: [String]?
    let filesWritten: [String]?

    static func from(_ p: [String: AnyCodable]) -> SubagentCompletePayload {
        SubagentCompletePayload(
            goal: p["goal"]?.stringValue ?? "",
            taskCount: p["task_count"]?.intValue ?? 1,
            taskIndex: p["task_index"]?.intValue ?? 0,
            subagentID: p["subagent_id"]?.stringValue,
            parentID: p["parent_id"]?.stringValue,
            depth: p["depth"]?.intValue,
            inputTokens: p["input_tokens"]?.intValue,
            outputTokens: p["output_tokens"]?.intValue,
            apiCalls: p["api_calls"]?.intValue,
            costUSD: p["cost_usd"]?.doubleValue,
            filesRead: p["files_read"]?.arrayValue?.map { $0.stringValue ?? "" },
            filesWritten: p["files_written"]?.arrayValue?.map { $0.stringValue ?? "" }
        )
    }
}

struct SubagentToolPayload {
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let subagentID: String?
    let toolName: String?
    let toolPreview: String?
    let text: String?

    static func from(_ p: [String: AnyCodable]) -> SubagentToolPayload {
        SubagentToolPayload(
            goal: p["goal"]?.stringValue ?? "",
            taskCount: p["task_count"]?.intValue ?? 1,
            taskIndex: p["task_index"]?.intValue ?? 0,
            subagentID: p["subagent_id"]?.stringValue,
            toolName: p["tool_name"]?.stringValue,
            toolPreview: p["tool_preview"]?.stringValue,
            text: p["text"]?.stringValue
        )
    }
}
