import SwiftUI

/// Renders ```tree blocks as a real file hierarchy: type icons, indent
/// guides, and collapsible directories — instead of box-drawing ASCII in a
/// code block.
///
/// Accepts the two shapes models actually emit:
/// - box-drawing / ASCII trees (`├── src`, `│   └── main.swift`, `|-- lib`)
/// - plain indentation (2 or 4 spaces per level), directories ending in `/`
struct FileTreeView: View {
    let code: String
    @State private var collapsed: Set<Int> = []

    /// Parse once per distinct tree source, not on every render/collapse toggle.
    private static let parseMemo = RenderMemo<[FileTreeNode]>(limit: 24)
    private var nodes: [FileTreeNode] { Self.parseMemo.value(for: code) { FileTreeNode.parse(code) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border.opacity(0.5))
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleNodes) { node in
                        row(node)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Spacer()
            if nodes.contains(where: { $0.isDirectory }) {
                Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                    if collapsed.isEmpty {
                        collapsed = Set(nodes.filter(\.isDirectory).map(\.id))
                    } else {
                        collapsed = []
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Nodes not hidden inside a collapsed ancestor directory.
    private var visibleNodes: [FileTreeNode] {
        var hiddenBelow: Int?
        return nodes.filter { node in
            if let level = hiddenBelow {
                if node.depth > level { return false }
                hiddenBelow = nil
            }
            if node.isDirectory && collapsed.contains(node.id) {
                hiddenBelow = node.depth
            }
            return true
        }
    }

    private func row(_ node: FileTreeNode) -> some View {
        HStack(spacing: 5) {
            // Indent guides — one hairline per ancestor level.
            ForEach(0..<node.depth, id: \.self) { _ in
                Rectangle()
                    .fill(Theme.border.opacity(0.6))
                    .frame(width: 1)
                    .padding(.leading, 7)
                    .padding(.trailing, 6)
            }
            if node.isDirectory {
                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: node.icon)
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Theme.accent : Theme.secondary)
            Text(node.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
            if let annotation = node.annotation {
                Text(annotation)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            guard node.isDirectory else { return }
            if collapsed.contains(node.id) {
                collapsed.remove(node.id)
            } else {
                collapsed.insert(node.id)
            }
        }
    }
}

// MARK: - Node model

struct FileTreeNode: Identifiable {
    let id: Int
    let depth: Int
    let name: String
    /// Trailing comment ("# entry point", "— 12 files") if present.
    let annotation: String?
    let isDirectory: Bool

    var icon: String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "py", "rb", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rst": return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns": return "photo"
        case "mp4", "mov", "webm": return "film"
        case "mp3", "wav", "m4a": return "waveform"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "shippingbox"
        case "lock": return "lock"
        default: return "doc"
        }
    }

    /// Parse box-drawing / ASCII / indent trees. For box-drawing lines depth
    /// is one level per 4-column segment/connector; for plain-indent trees
    /// the indent unit is inferred from the smallest nonzero indent (so both
    /// 2- and 4-space trees map to one level per step).
    static func parse(_ code: String) -> [FileTreeNode] {
        var nodes: [FileTreeNode] = []

        let lines = code.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Indent unit for plain (no box-drawing/connector) trees.
        let plainIndents = lines.compactMap { line -> Int? in
            guard !containsConnector(line) else { return nil }
            let spaces = line.prefix { $0 == " " }.count
            return spaces > 0 ? spaces : nil
        }
        let indentUnit = plainIndents.min() ?? 2

        for (index, rawLine) in lines.enumerated() {
            guard let (depth, rest) = splitPrefix(rawLine, indentUnit: indentUnit) else { continue }

            // Trailing annotation: "name  # comment" or "name — note".
            var name = rest
            var annotation: String?
            for marker in ["  #", "  //", "  —", "  --", " #"] {
                if let range = name.range(of: marker) {
                    annotation = String(name[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " #/—-"))
                    name = String(name[..<range.lowerBound])
                    break
                }
            }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            let explicitDir = name.hasSuffix("/")
            if explicitDir { name = String(name.dropLast()) }

            nodes.append(FileTreeNode(
                id: index,
                depth: depth,
                name: name,
                annotation: annotation?.isEmpty == false ? annotation : nil,
                isDirectory: explicitDir
            ))
        }

        // Second pass: a node with children deeper than itself is a
        // directory even without a trailing slash.
        return nodes.enumerated().map { i, node in
            if node.isDirectory { return node }
            let hasChildren = i + 1 < nodes.count && nodes[i + 1].depth > node.depth
            guard hasChildren else { return node }
            return FileTreeNode(
                id: node.id, depth: node.depth, name: node.name,
                annotation: node.annotation, isDirectory: true
            )
        }
    }

    private static let connectors = ["├── ", "└── ", "├─ ", "└─ ", "|-- ", "`-- ", "+-- "]

    private static func containsConnector(_ line: String) -> Bool {
        connectors.contains { line.contains($0) } || line.contains("│")
    }

    /// Strip the tree-prefix from a line, returning (depth, remainder).
    /// Box-drawing lines count 4-column segments + a connector; plain lines
    /// count leading spaces in units of `indentUnit`.
    private static func splitPrefix(_ line: String, indentUnit: Int) -> (Int, String)? {
        if containsConnector(line) {
            var depth = 0
            var rest = Substring(line)
            while true {
                // Pass-through segments: "│   " / "|   " / "    " (4 cols).
                if rest.hasPrefix("│   ") || rest.hasPrefix("|   ") || rest.hasPrefix("    ") {
                    depth += 1
                    rest = rest.dropFirst(4)
                    continue
                }
                for connector in connectors where rest.hasPrefix(connector) {
                    return (depth + 1, String(rest.dropFirst(connector.count)))
                }
                break
            }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return (depth, trimmed)
        }

        // Plain-indent line: leading spaces / indentUnit.
        let spaces = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (spaces / max(1, indentUnit), trimmed)
    }
}
