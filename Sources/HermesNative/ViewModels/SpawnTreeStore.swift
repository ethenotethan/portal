import Foundation
import Combine

/// Accumulates gateway subagent/delegation events into a live spawn tree per session.
/// Each session has a root node (the user's prompt) with children for delegated subagents.
@MainActor
final class SpawnTreeStore: ObservableObject {
    @Published var sessions: [SessionTree] = []
    @Published var activeSessionID: String?
    @Published var delegationStatus: DelegationStatus?

    private var cancellables = Set<AnyCancellable>()

    /// Buffer for events that arrive before a tree is created for their session.
    /// Keyed by sessionID; flushed when createTree() is called.
    private var eventBuffer: [String: [(GatewayEvent)]] = [:]

    /// The active session tree (if any).
    var activeTree: SessionTree? {
        sessions.first { $0.sessionID == activeSessionID }
    }

    // MARK: - Event Subscription

    /// Subscribe to gateway events from the given client.
    func subscribe(to client: GatewayClient) {
        client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, sessionID in
                self?.handleEvent(event, sessionID: sessionID)
            }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: GatewayEvent, sessionID: String?) {
        let sid = sessionID ?? activeSessionID ?? ""

        // Find tree for this session
        let tree = sessions.first { $0.sessionID == sid }

        // If no tree exists yet, buffer the event
        if tree == nil && !sid.isEmpty {
            eventBuffer[sid, default: []].append(event)
        }

        // Process the event against the tree (if it exists)
        processEvent(event, tree: tree)
    }

    private func processEvent(_ event: GatewayEvent, tree: SessionTree?) {
        switch event {
        case .messageStart:
            tree?.root.status = .running

        case .subagentSpawnRequested(let payload):
            upsertNode(
                id: payload.subagentID ?? UUID().uuidString,
                goal: payload.goal,
                taskCount: payload.taskCount,
                taskIndex: payload.taskIndex,
                parentID: payload.parentID,
                depth: payload.depth ?? 0,
                model: payload.model,
                status: .queued,
                tree: tree
            )

        case .subagentStart(let payload):
            upsertNode(
                id: payload.subagentID ?? UUID().uuidString,
                goal: payload.goal,
                taskCount: payload.taskCount,
                taskIndex: payload.taskIndex,
                parentID: payload.parentID,
                depth: payload.depth ?? 0,
                model: payload.model,
                status: .running,
                tree: tree
            )

        case .subagentComplete(let payload):
            let nodeID = payload.subagentID ?? ""
            updateNode(id: nodeID, tree: tree) { node in
                node.status = .completed
                node.costUSD = payload.costUSD
                node.inputTokens = payload.inputTokens
                node.outputTokens = payload.outputTokens
                node.apiCalls = payload.apiCalls
                node.filesRead = payload.filesRead ?? []
                node.filesWritten = payload.filesWritten ?? []
                node.completedAt = Date()
            }

        case .subagentTool(let payload):
            let nodeID = payload.subagentID ?? ""
            updateNode(id: nodeID, tree: tree) { node in
                let toolCall = NodeToolCall(
                    name: payload.toolName ?? "tool",
                    preview: payload.toolPreview ?? payload.text,
                    isComplete: true
                )
                node.toolCalls.append(toolCall)
            }

        case .subagentProgress:
            break

        case .subagentThinking:
            break

        case .messageComplete(let payload):
            tree?.root.status = payload.status == "complete" ? .completed
                : payload.status == "interrupted" ? .interrupted
                : payload.status == "error" ? .failed
                : .completed
            tree?.root.completedAt = Date()

        case .toolStart(let payload):
            let toolCall = NodeToolCall(
                id: payload.toolID,
                name: payload.name,
                preview: payload.context
            )
            tree?.root.toolCalls.append(toolCall)

        case .toolComplete(let payload):
            if let tree, let idx = tree.root.toolCalls.firstIndex(where: { $0.id == payload.toolID }) {
                tree.root.toolCalls[idx].summary = payload.summary
                tree.root.toolCalls[idx].durationSeconds = payload.durationSeconds
                tree.root.toolCalls[idx].isComplete = true
            }

        case .toolProgress(let name, let preview):
            if let tree, let idx = tree.root.toolCalls.firstIndex(where: { $0.name == name && !$0.isComplete }) {
                tree.root.toolCalls[idx].preview = preview
            }

        case .thinkingDelta(let text):
            if let tree, tree.root.status.isRunning {
                tree.root.thinkingText += text
            }

        case .messageDelta(let text, _):
            tree?.root.transcript.append(
                NodeTranscriptEntry(role: .assistant, content: text)
            )

        default:
            break
        }
    }

    // MARK: - Tree Management

    /// Create a new session tree. If one already exists for this sessionID,
    /// just activate it (don't wipe it).
    func createTree(sessionID: String, prompt: String = "") {
        // Don't recreate if tree already exists
        if sessions.contains(where: { $0.sessionID == sessionID }) {
            activeSessionID = sessionID
            return
        }

        let root = SpawnNode(
            id: "root_\(sessionID)",
            goal: prompt,
            status: prompt.isEmpty ? .queued : .running
        )
        let tree = SessionTree(sessionID: sessionID, root: root)
        sessions.append(tree)
        activeSessionID = sessionID

        // Flush any buffered events for this session
        if let buffered = eventBuffer.removeValue(forKey: sessionID) {
            for event in buffered {
                processEvent(event, tree: tree)
            }
        }
    }

    /// Set the active session.
    func setActive(sessionID: String) {
        activeSessionID = sessionID
    }

    /// Remove a session tree.
    func removeTree(sessionID: String) {
        sessions.removeAll { $0.sessionID == sessionID }
        eventBuffer.removeValue(forKey: sessionID)
        if activeSessionID == sessionID {
            activeSessionID = sessions.first?.sessionID
        }
    }

    // MARK: - Node Operations

    private func upsertNode(
        id: String,
        goal: String,
        taskCount: Int = 1,
        taskIndex: Int = 0,
        parentID: String?,
        depth: Int = 0,
        model: String? = nil,
        status: NodeStatus = .queued,
        tree: SessionTree?
    ) {
        // Find existing node across all trees
        for t in sessions {
            if let existing = t.findNode(id: id) {
                existing.status = status
                return
            }
        }

        // Create new node
        let node = SpawnNode(
            id: id,
            goal: goal,
            depth: depth,
            taskCount: taskCount,
            taskIndex: taskIndex,
            parentID: parentID,
            model: model,
            status: status
        )

        // Find parent and attach
        if let parentID {
            for t in sessions {
                if let parent = t.findNode(id: parentID) {
                    parent.children.append(node)
                    return
                }
            }
        }

        // No parent found — attach to the provided tree's root
        if let tree {
            node.parentID = tree.root.id
            tree.root.children.append(node)
        }
    }

    private func updateNode(id: String, tree: SessionTree?, update: (SpawnNode) -> Void) {
        // Search provided tree first, then all trees
        if let tree, let node = tree.findNode(id: id) {
            update(node)
            return
        }
        for t in sessions {
            if let node = t.findNode(id: id) {
                update(node)
                return
            }
        }
    }
}

// MARK: - Session Tree

/// A tree of spawn nodes for a single agent session.
class SessionTree: ObservableObject, Identifiable {
    let id = UUID()
    let sessionID: String
    @Published var root: SpawnNode

    init(sessionID: String, root: SpawnNode) {
        self.sessionID = sessionID
        self.root = root
    }

    /// Recursively find a node by ID.
    func findNode(id: String) -> SpawnNode? {
        findNode(in: root, id: id)
    }

    private func findNode(in node: SpawnNode, id: String) -> SpawnNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(in: child, id: id) {
                return found
            }
        }
        return nil
    }

    /// Total node count (root + all descendants).
    var nodeCount: Int {
        1 + root.allDescendants.count
    }

    /// Whether any node in the tree is still running.
    var isRunning: Bool {
        root.status.isRunning || root.allDescendants.contains { $0.status.isRunning }
    }

    /// Total cost across all nodes.
    var totalCost: Double {
        let rootCost = root.costUSD ?? 0
        let childCosts = root.allDescendants.compactMap { $0.costUSD }.reduce(0, +)
        return rootCost + childCosts
    }
}

// MARK: - Delegation Status

struct DelegationStatus {
    let maxSpawnDepth: Int?
    let maxConcurrentChildren: Int?
    let activeSubagents: Int
    let totalSubagents: Int
}
