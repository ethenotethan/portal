import SwiftUI

/// Status color shared by Mission Control views.
func colorForStatus(_ status: NodeStatus) -> Color {
    switch status {
    case .queued:      .secondary
    case .running:     .blue
    case .completed:   .green
    case .failed:      .red
    case .interrupted: .orange
    }
}

/// A node in the agent's spawn tree — represents a root prompt or a subagent.
/// Recursive structure: root prompt → children (delegated subagents) → their children, etc.
class SpawnNode: Identifiable, ObservableObject, Hashable {
    let id: String
    let goal: String
    let depth: Int
    let taskCount: Int
    let taskIndex: Int
    var parentID: String?
    let model: String?
    let createdAt: Date

    @Published var status: NodeStatus
    @Published var children: [SpawnNode] = []
    @Published var toolCalls: [NodeToolCall] = []
    @Published var transcript: [NodeTranscriptEntry] = []
    @Published var thinkingText: String = ""
    @Published var costUSD: Double?
    @Published var inputTokens: Int?
    @Published var outputTokens: Int?
    @Published var apiCalls: Int?
    @Published var filesRead: [String] = []
    @Published var filesWritten: [String] = []
    @Published var completedAt: Date?

    init(
        id: String,
        goal: String,
        depth: Int = 0,
        taskCount: Int = 1,
        taskIndex: Int = 0,
        parentID: String? = nil,
        model: String? = nil,
        status: NodeStatus = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.depth = depth
        self.taskCount = taskCount
        self.taskIndex = taskIndex
        self.parentID = parentID
        self.model = model
        self.status = status
        self.createdAt = createdAt
    }

    /// Duration since creation (or creation → completion if done).
    var duration: TimeInterval {
        let end = completedAt ?? Date()
        return end.timeIntervalSince(createdAt)
    }

    /// Formatted duration string.
    var durationString: String {
        let d = duration
        if d < 60 { return String(format: "%.0fs", d) }
        if d < 3600 { return String(format: "%.1fm", d / 60) }
        return String(format: "%.1fh", d / 3600)
    }

    /// Total token count.
    var totalTokens: Int? {
        guard let i = inputTokens, let o = outputTokens else { return nil }
        return i + o
    }

    /// Count of running descendants.
    var runningDescendantCount: Int {
        children.reduce(0) { $0 + ($1.status.isRunning ? 1 : 0) + $1.runningDescendantCount }
    }

    /// Flat list of all descendant nodes.
    var allDescendants: [SpawnNode] {
        children.flatMap { [$0] + $0.allDescendants }
    }

    // MARK: - Hashable

    static func == (lhs: SpawnNode, rhs: SpawnNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension SpawnNode {
    /// Transcript entries normalized for display. Older in-memory trees may have
    /// been built from token/word-level deltas, so compact adjacent entries with
    /// the same role as a defensive UI fallback.
    var readableTranscript: [NodeTranscriptEntry] {
        transcript.reduce(into: [NodeTranscriptEntry]()) { result, entry in
            guard !entry.content.isEmpty else { return }
            if let last = result.indices.last, result[last].role == entry.role {
                result[last].content += entry.content
            } else {
                result.append(entry)
            }
        }
    }
}

// MARK: - Node Status

enum NodeStatus: String, Equatable {
    case queued
    case running
    case completed
    case failed
    case interrupted

    var isRunning: Bool { self == .running || self == .queued }
    var isTerminal: Bool { self == .completed || self == .failed || self == .interrupted }

    /// SF Symbol icon for this status.
    var iconName: String {
        switch self {
        case .queued:      "circle.dashed"
        case .running:     "circle.fill"
        case .completed:   "checkmark.circle.fill"
        case .failed:      "xmark.circle.fill"
        case .interrupted: "pause.circle.fill"
        }
    }
}

// MARK: - Node Tool Call

struct NodeToolCall: Identifiable {
    let id: String
    let name: String
    var preview: String?
    var summary: String?
    var durationSeconds: Double?
    var isComplete: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        preview: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        isComplete: Bool = false
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.isComplete = isComplete
    }
}

// MARK: - Node Transcript Entry

struct NodeTranscriptEntry: Identifiable {
    let id: UUID
    let role: Role
    var content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum Role {
        case user
        case assistant
        case tool
    }
}
