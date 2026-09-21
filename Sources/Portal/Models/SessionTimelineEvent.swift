import SwiftUI

// MARK: - Event Type Enum

enum EventType: String, Codable, CaseIterable {
    case userMessage
    case assistantMessage
    case toolStart
    case toolEnd
    case reasoningBlock
    case turnBoundary

    var iconName: String {
        switch self {
        case .userMessage:      return "person.fill"
        case .assistantMessage: return "sparkles"
        case .toolStart:        return "gearshape.fill"
        case .toolEnd:          return "checkmark.circle.fill"
        case .reasoningBlock:   return "brain.head.profile"
        case .turnBoundary:     return "line.diagonal"
        }
    }

    var colorHex: String {
        switch self {
        case .userMessage:      return "#888888"
        case .assistantMessage: return "#7c7cff"
        case .toolStart:        return "#f0a040"
        case .toolEnd:          return "#40c040"
        case .reasoningBlock:   return "#ff8c00"
        case .turnBoundary:     return "#444444"
        }
    }
}

// MARK: - Session Timeline Event

struct SessionTimelineEvent: Identifiable, Codable {
    let id: String
    let type: EventType
    let timestamp: Date
    let content: String?
    let toolName: String?
    let toolID: String?
    let durationMs: Double?
    let tokenCount: Int?
    let summary: String?
}

// MARK: - Session Timeline

struct SessionTimeline: Codable, TokenAccountable {
    let sessionID: String
    let events: [SessionTimelineEvent]
    let totalDurationSeconds: Double
    let toolCalls: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Double?

    var totalTokens: Int? {
        guard let i = inputTokens, let o = outputTokens else { return nil }
        return i + o
    }
    var toolCallsCount: Int { toolCalls }
}
