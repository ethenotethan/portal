import Foundation

/// The "where" lens: aggregates a turn's tool nodes into the directory tree of
/// files it TOUCHED — read/write/patch/search targets clustered by folder — so
/// you can see where the agent is working and how its context accretes, not
/// just the raw tool bars.
///
/// Best-effort by design: built from `ThoughtGraphNode.confidentFilePath`
/// (regex over the tool's preview text), so it shows only files it recognizes.
/// A tool with no parseable path simply doesn't appear — the tree is labeled
/// "files touched", not a filesystem mirror.
internal enum FileTouchAction: String {
    case read, write, patch, search, other

    /// Precedence when a file is touched by several actions — a written file
    /// is "hotter" than one merely read. Higher wins for the node's color.
    internal var heat: Int {
        switch self {
        case .write, .patch: return 3
        case .search: return 2
        case .read: return 1
        case .other: return 0
        }
    }

    internal static func from(category: ThoughtGraphLayoutEngine.ToolCategory) -> FileTouchAction {
        switch category {
        case .read: return .read
        case .write: return .write
        case .patch: return .patch
        case .search: return .search
        default: return .other
        }
    }
}

/// One node in the aggregated file tree — a directory or a file.
internal final class TouchedFileNode: Identifiable {
    internal let id: String            // full path from root
    internal let name: String          // this segment
    internal let isDirectory: Bool
    internal var children: [TouchedFileNode] = []

    /// For files: the thought-graph node ids that touched this file (drives
    /// cross-highlighting with the timeline) and the dominant action (heat).
    internal var touchingNodeIDs: [String] = []
    internal var dominantAction: FileTouchAction = .other
    /// Number of times this file was touched (recency/attention signal).
    internal var touchCount: Int = 0

    internal init(id: String, name: String, isDirectory: Bool) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
    }
}

internal enum FileTreeAggregator {

    /// Build the touched-files tree for a set of thought-graph nodes. Files
    /// are keyed by their confident path; directory nodes are synthesized for
    /// each path segment. Returns the root children (top-level dirs/files),
    /// each sorted directories-first then alphabetically.
    internal static func build(from nodes: [ThoughtGraphNode]) -> [TouchedFileNode] {
        // path → accumulated file record
        var fileByPath: [String: TouchedFileNode] = [:]
        var order: [String] = []

        for node in nodes {
            guard let path = node.confidentFilePath else { continue }
            let normalized = normalize(path)
            guard !normalized.isEmpty else { continue }
            let file: TouchedFileNode
            if let existing = fileByPath[normalized] {
                file = existing
            } else {
                file = TouchedFileNode(
                    id: normalized,
                    name: normalized.split(separator: "/").last.map(String.init) ?? normalized,
                    isDirectory: false
                )
                fileByPath[normalized] = file
                order.append(normalized)
            }
            file.touchingNodeIDs.append(node.id)
            file.touchCount += 1
            let action = FileTouchAction.from(category: node.category)
            if action.heat > file.dominantAction.heat { file.dominantAction = action }
        }

        guard !order.isEmpty else { return [] }

        // Build the directory hierarchy from the flat file list.
        let root = TouchedFileNode(id: "", name: "", isDirectory: true)
        for path in order {
            guard let file = fileByPath[path] else { continue }
            insert(file: file, at: path, into: root)
        }
        return sorted(root.children)
    }

    // MARK: - Private

    private static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        // Strip a leading ./ so "./a/b" and "a/b" collapse; keep ~/ and / as-is.
        if p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    /// Walk the path segments, creating directory nodes as needed, and hang
    /// the file off its parent directory.
    private static func insert(file: TouchedFileNode, at path: String, into root: TouchedFileNode) {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count > 1 else {
            root.children.append(file)   // top-level file
            return
        }
        var cursor = root
        var prefix = ""
        for dirSegment in segments.dropLast() {
            prefix = prefix.isEmpty ? dirSegment : "\(prefix)/\(dirSegment)"
            if let existing = cursor.children.first(where: { $0.isDirectory && $0.name == dirSegment }) {
                cursor = existing
            } else {
                let dir = TouchedFileNode(id: prefix, name: dirSegment, isDirectory: true)
                cursor.children.append(dir)
                cursor = dir
            }
        }
        cursor.children.append(file)
    }

    /// Directories first, then files, each alphabetically — recursively.
    private static func sorted(_ nodes: [TouchedFileNode]) -> [TouchedFileNode] {
        for node in nodes where node.isDirectory {
            node.children = sorted(node.children)
        }
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
