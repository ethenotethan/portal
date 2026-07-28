import Foundation

// MARK: - Thought Graph Node

/// A single node in the live agent thought graph DAG, representing one tool invocation
/// during an active chat streaming turn. Rendered as a node in the visualization with
/// dependency edges connecting to parent nodes.
struct ThoughtGraphNode: Identifiable, Codable, ToolCallRepresentable, TokenAccountable {
    /// The tool_call_id from gateway events (tool.start / tool.complete).
    let id: String

    /// Tool name (e.g. "read_file", "search_files", "patch").
    var name: String

    /// Preview text from the tool.start event.
    var context: String?

    /// Summary text from the tool.complete event.
    var summary: String?

    /// Whether the tool invocation has finished (tool.complete received).
    var isComplete: Bool

    /// Whether the tool completed with an error.
    var isError: Bool

    /// Elapsed wall-clock seconds from the tool.complete payload.
    var durationSeconds: Double?

    /// Inferred depth in the DAG. 0 = root node (no parent dependencies).
    var depth: Int

    /// Inferred parent toolIDs that this node depends on.
    var parentIDs: [String]

    /// Timestamp when the tool.start event arrived.
    var startedAt: Date?

    /// Timestamp when the tool.complete event arrived.
    var completedAt: Date?

    // MARK: - Subagent Identity
    //
    // Two disjoint roles: a node with `agentID` IS a spawned subagent (its
    // react loop rendered as a subtree); a node with `ownerAgentID` is a tool
    // call executed INSIDE that subagent's loop. Plain parent-session tool
    // calls have neither.

    /// What KIND of thing this node is — set explicitly at construction so a
    /// node's role never has to be inferred from its `name`.
    ///
    /// History: reasoning beats used to be identified only by the magic string
    /// `name == "reasoning"` (see `ToolCategory.classify`). Any reasoning node
    /// whose name wasn't exactly that string — e.g. a harness reasoning item
    /// that slipped through an adapter's default tool branch — fell through the
    /// tool-list filters (`category != .reasoning`) and drew a phantom "thinking"
    /// tool row. An explicit role closes that seam: reasoning is reasoning
    /// because it was built as reasoning, not because of how it happens to be
    /// named. Optional + decoded-if-present so sessions persisted before this
    /// field load cleanly (see `category` for the legacy name-based fallback).
    internal var role: Role?

    /// The `subagent_id` when this node represents a spawned subagent.
    var agentID: String?

    /// The owning subagent's `subagent_id` when this node is a tool call
    /// made from within that subagent's loop.
    var ownerAgentID: String?

    /// Model the subagent runs on (agent nodes only).
    var modelName: String?

    /// Cost/token rollup from subagent.complete (agent nodes only).
    var costUSD: Double?
    var totalTokens: Int?
    var inputTokens: Int? { nil }
    var outputTokens: Int? { nil }

    /// Tail of the subagent's live thinking stream, for the detail panel.
    var agentThinking: String?

    // MARK: - Computed

    /// The role of a thought-graph node. A node is reasoning/agent/tool because
    /// it was BUILT that way — not because of how its `name` reads.
    internal enum Role: String, Codable {
        case tool       // a tool invocation (the default)
        case reasoning  // an interleaved thought beat
        case agent      // a spawned subagent subtree
    }

    /// Whether this node represents a spawned subagent (vs. a tool call).
    /// `agentID` remains the source of truth for the subagent SUBTREE identity;
    /// `role == .agent` is set alongside it so the role is self-describing too.
    var isAgent: Bool { agentID != nil }

    /// Whether this node is a reasoning beat. True when the role is explicitly
    /// reasoning OR the name classifies as reasoning. The name check is a
    /// defensive fallback (no real tool is ever named exactly "reasoning"), so a
    /// node persisted before `role` existed, or any caller that still builds a
    /// bare `name: "reasoning"` node without setting the role, still reads as
    /// reasoning — and stays consistent with `category`, which also treats that
    /// name as reasoning. Explicit `role` is what catches a reasoning beat whose
    /// name is anything ELSE, which is the seam the phantom-tool-row bug rode.
    internal var isReasoning: Bool {
        if role == .reasoning { return true }
        return ThoughtGraphLayoutEngine.ToolCategory.classify(name: name) == .reasoning
    }

    /// Derived node status for rendering.
    var status: ThoughtNodeStatus {
        if isError {
            return .error
        } else if isComplete {
            return .completed
        } else {
            return .running
        }
    }

    /// Whether this is a root node (no parent dependencies).
    var isRoot: Bool { depth == 0 && parentIDs.isEmpty }

    /// Tool category derived from the node's role first, then its name. Role
    /// wins so a reasoning/agent node can never be miscategorised as a tool just
    /// because of its name; only genuine tool nodes fall through to the
    /// name-based classifier for their read/write/search/etc. sub-category.
    var category: ThoughtGraphLayoutEngine.ToolCategory {
        if isAgent { return .agent }
        if isReasoning { return .reasoning }
        return ThoughtGraphLayoutEngine.ToolCategory.classify(name: name)
    }

    /// Extract the file path or target from the tool's context string.
    /// For tools like write_file/read_file, the context typically contains
    /// the file path. This extracts it for display as a node subtitle.
    var extractedFilePath: String? {
        guard let ctx = context else { return nil }
        // Common patterns in tool contexts: "Writing /path/to/file.ext"
        let filePatterns = [
            #"(?:Writing|Reading|Creating|Editing|Modifying|Updating|Saving|Opening|Processing|{})? ?([/~\.]{1,2}[\w/\-\.]+)"#,
        ]
        for pattern in filePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: ctx, range: NSRange(ctx.startIndex..<ctx.endIndex, in: ctx)),
               match.numberOfRanges > 1,
               match.range(at: 1).location != NSNotFound {
                let path = (ctx as NSString).substring(with: match.range(at: 1))
                let trimmed = path.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        // Fallback: return first line of context if it's short
        let firstLine = ctx.components(separatedBy: "\n").first ?? ""
        return firstLine.count <= 60 ? firstLine : nil
    }

    /// Compiled once — a path token: optional leading ./ ~ /, then dir
    /// segments, ending in a filename with an extension (so bare words / prose
    /// don't match). Force-tried at load: a malformed literal is a programmer
    /// error we want to surface in tests, not silently swallow at call time.
    private static let confidentPathRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"((?:\.{1,2}/|~/|/)?(?:[\w\-.]+/)*[\w\-]+\.[A-Za-z0-9]{1,6})"#
    )

    /// A CONFIDENT file path for the file-tree lens — only real path shapes
    /// (a slash-bearing token with a file-ish tail), never the loose
    /// first-line fallback `extractedFilePath` allows. Returns nil when we
    /// can't be sure, so the tree shows only files it actually recognizes
    /// ("files touched", not a guess). Also gates on file-touching categories.
    internal var confidentFilePath: String? {
        switch category {
        case .read, .write, .patch, .search: break
        default: return nil
        }
        guard let ctx = context else { return nil }
        let regex = Self.confidentPathRegex
        let ns = ctx as NSString
        guard let match = regex.firstMatch(in: ctx, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let path = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        // Reject degenerate matches (e.g. "1.0", "v2.3") — require a slash OR a
        // known-code-ish extension so version strings don't populate the tree.
        guard path.contains("/") || path.count >= 5 else { return nil }
        return path
    }

    // MARK: - Initializer

    init(
        id: String,
        name: String,
        context: String? = nil,
        summary: String? = nil,
        isComplete: Bool = false,
        isError: Bool = false,
        durationSeconds: Double? = nil,
        depth: Int = 0,
        parentIDs: [String] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        role: Role = .tool,
        agentID: String? = nil,
        ownerAgentID: String? = nil,
        modelName: String? = nil,
        costUSD: Double? = nil,
        totalTokens: Int? = nil,
        agentThinking: String? = nil
    ) {
        self.id = id
        self.name = name
        self.context = context
        self.summary = summary
        self.isComplete = isComplete
        self.isError = isError
        self.durationSeconds = durationSeconds
        self.depth = depth
        self.parentIDs = parentIDs
        self.startedAt = startedAt
        self.completedAt = completedAt
        // A node with an agentID is a subagent regardless of what the caller
        // passed; otherwise honour the explicit role (default .tool).
        self.role = agentID != nil ? .agent : role
        self.agentID = agentID
        self.ownerAgentID = ownerAgentID
        self.modelName = modelName
        self.costUSD = costUSD
        self.totalTokens = totalTokens
        self.agentThinking = agentThinking
    }

    // MARK: - Factory

    /// Create a ThoughtGraphNode from an existing ToolCallRecord.
    /// The ToolCallRecord lacks depth/parentIDs/startedAt/completedAt,
    /// so those are left at defaults; callers should set them after construction.
    static func from(toolCall: ToolCallRecord) -> ThoughtGraphNode {
        ThoughtGraphNode(
            id: toolCall.id,
            name: toolCall.name,
            context: toolCall.context,
            summary: toolCall.summary,
            isComplete: toolCall.isComplete,
            isError: false,
            durationSeconds: toolCall.durationSeconds,
            depth: 0,
            parentIDs: [],
            startedAt: toolCall.startedAt,
            completedAt: toolCall.completedAt
        )
    }
}

// MARK: - Thought Node Status

/// Runtime status of a thought graph node.
enum ThoughtNodeStatus: String, Codable {
    /// Tool is currently executing (tool.start received, no tool.complete yet).
    case running

    /// Tool completed successfully.
    case completed

    /// Tool completed with an error.
    case error
}

// MARK: - Thought Graph

/// The full thought graph for a single conversation turn (one assistant message).
/// Represents the live DAG of tool invocations during active streaming.
struct ThoughtGraph: Codable {
    /// The session identifier this graph belongs to.
    let sessionID: String

    /// All tool-call nodes in this turn.
    var nodes: [ThoughtGraphNode]

    /// Whether the turn is still streaming (new nodes may still arrive).
    var isActive: Bool

    // MARK: - Initializer

    init(
        sessionID: String,
        nodes: [ThoughtGraphNode] = [],
        isActive: Bool = true
    ) {
        self.sessionID = sessionID
        self.nodes = nodes
        self.isActive = isActive
    }

    // MARK: - Computed

    /// Root nodes (depth 0, no parents).
    var rootNodes: [ThoughtGraphNode] {
        nodes.filter { $0.isRoot }
    }

    /// Find a node by its tool ID.
    func node(for toolID: String) -> ThoughtGraphNode? {
        nodes.first { $0.id == toolID }
    }

    /// All edges as (parentID, childID) pairs for rendering.
    var edges: [(String, String)] {
        var result: [(String, String)] = []
        for node in nodes {
            for parentID in node.parentIDs {
                result.append((parentID, node.id))
            }
        }
        return result
    }
}

// MARK: - Thought Graph Layout

/// Layout information for a single node in the thought graph visualization.
/// Stores the computed position and size for rendering.
///
/// CGPoint and CGSize are not directly Codable, so this struct uses
/// Double-based coordinates internally and maps to/from CoreGraphics types.
struct ThoughtGraphLayout: Codable {
    /// The node this layout applies to.
    let nodeID: String

    /// Horizontal position in the layout coordinate space.
    var x: Double

    /// Vertical position in the layout coordinate space.
    var y: Double

    /// Width of the node.
    var width: Double

    /// Height of the node.
    var height: Double

    // MARK: - CoreGraphics Mapping

    /// The position as a CoreGraphics point (for view-layer use).
    #if canImport(CoreGraphics)
    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    /// The size as a CoreGraphics size (for view-layer use).
    var size: CGSize {
        get { CGSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }
    #endif

    // MARK: - Initializers

    init(nodeID: String, x: Double, y: Double, width: Double, height: Double) {
        self.nodeID = nodeID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    #if canImport(CoreGraphics)
    init(nodeID: String, position: CGPoint, size: CGSize) {
        self.nodeID = nodeID
        self.x = position.x
        self.y = position.y
        self.width = size.width
        self.height = size.height
    }
    #endif
}
