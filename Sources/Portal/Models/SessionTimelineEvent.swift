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

struct SessionTimeline: Codable {
    let sessionID: String
    let events: [SessionTimelineEvent]
    let totalDurationSeconds: Double
    let toolCalls: Int
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double?

    var toolCallsCount: Int { toolCalls }

    static func mock(sessionID: String) -> SessionTimeline {
        let baseTime = Date().timeIntervalSince1970 - 45.2
        let events: [SessionTimelineEvent] = [
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-1", type: .userMessage, timestamp: Date(timeIntervalSince1970: baseTime), content: "Build a SwiftUI markdown parser that handles code blocks and tables.", toolName: nil, toolID: nil, durationMs: nil, tokenCount: nil, summary: nil),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-2", type: .toolStart, timestamp: Date(timeIntervalSince1970: baseTime + 0.5), content: nil, toolName: "search_files", toolID: "call_01", durationMs: nil, tokenCount: nil, summary: "Searching for *.swift in Sources/"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-3", type: .toolEnd, timestamp: Date(timeIntervalSince1970: baseTime + 2.1), content: nil, toolName: "search_files", toolID: "call_01", durationMs: 1600, tokenCount: nil, summary: "Found 50 .swift files"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-4", type: .toolStart, timestamp: Date(timeIntervalSince1970: baseTime + 2.3), content: nil, toolName: "read_file", toolID: "call_02", durationMs: nil, tokenCount: nil, summary: "Reading MarkdownContentView.swift"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-5", type: .toolEnd, timestamp: Date(timeIntervalSince1970: baseTime + 2.7), content: nil, toolName: "read_file", toolID: "call_02", durationMs: 400, tokenCount: nil, summary: "Read 1300 lines"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-6", type: .toolStart, timestamp: Date(timeIntervalSince1970: baseTime + 2.9), content: nil, toolName: "read_file", toolID: "call_03", durationMs: nil, tokenCount: nil, summary: "Reading ChatMessage.swift"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-7", type: .toolEnd, timestamp: Date(timeIntervalSince1970: baseTime + 3.2), content: nil, toolName: "read_file", toolID: "call_03", durationMs: 300, tokenCount: nil, summary: "Read 350 lines"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-8", type: .reasoningBlock, timestamp: Date(timeIntervalSince1970: baseTime + 3.4), content: "MarkdownContentView already handles code blocks. I should extend it with diff support.", toolName: nil, toolID: nil, durationMs: nil, tokenCount: nil, summary: nil),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-9", type: .toolStart, timestamp: Date(timeIntervalSince1970: baseTime + 5.0), content: nil, toolName: "patch", toolID: "call_04", durationMs: nil, tokenCount: nil, summary: "Patching MarkdownContentView.swift"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-10", type: .toolEnd, timestamp: Date(timeIntervalSince1970: baseTime + 5.8), content: nil, toolName: "patch", toolID: "call_04", durationMs: 800, tokenCount: nil, summary: "Applied diff rendering"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-11", type: .toolStart, timestamp: Date(timeIntervalSince1970: baseTime + 6.0), content: nil, toolName: "terminal", toolID: "call_05", durationMs: nil, tokenCount: nil, summary: "Running swift build"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-12", type: .toolEnd, timestamp: Date(timeIntervalSince1970: baseTime + 17.5), content: nil, toolName: "terminal", toolID: "call_05", durationMs: 11500, tokenCount: nil, summary: "Build succeeded"),
            // swiftlint:disable:next line_length
            SessionTimelineEvent(id: "evt-13", type: .assistantMessage, timestamp: Date(timeIntervalSince1970: baseTime + 18.0), content: "I've added diff block rendering to the markdown parser.", toolName: nil, toolID: nil, durationMs: nil, tokenCount: 450, summary: nil),
        ]
        return SessionTimeline(sessionID: sessionID, events: events, totalDurationSeconds: 45.2, toolCalls: 5, inputTokens: 8500, outputTokens: 2100, costUSD: 0.034)
    }
}
