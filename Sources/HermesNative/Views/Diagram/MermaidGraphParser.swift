import Foundation

/// Best-effort parser that converts mermaid flowchart / graph / mindmap
/// sources into a `WikiGraph` so they can be explored as a force-directed graph.
/// Unparseable lines are silently skipped; the parser never throws.
enum MermaidGraphParser {

    private enum Kind {
        case flowchart
        case mindmap
    }

    // MARK: - Public API

    /// True when the (fence-stripped) source begins with a diagram type we can explore.
    static func canExplore(_ source: String) -> Bool {
        guard let header = cleanedLines(source).first else { return false }
        return diagramKind(of: header) != nil
    }

    /// Parses the source into a WikiGraph. Returns nil for unsupported diagram
    /// types or graphs with fewer than 2 nodes.
    static func parse(_ source: String) -> WikiGraph? {
        let lines = cleanedLines(source)
        guard let header = lines.first, let kind = diagramKind(of: header) else { return nil }

        let graph: WikiGraph
        switch kind {
        case .flowchart:
            graph = parseFlowchart(Array(lines.dropFirst()))
        case .mindmap:
            graph = parseMindmap(Array(lines.dropFirst()))
        }
        guard graph.pages.count >= 2 else { return nil }
        return graph
    }

    // MARK: - Source cleaning

    /// Removes ``` fences (including ```mermaid) and blank lines.
    /// Leading indentation is preserved (needed for mindmaps).
    private static func cleanedLines(_ source: String) -> [String] {
        source
            .components(separatedBy: .newlines)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("```")
            }
    }

    private static func diagramKind(of headerLine: String) -> Kind? {
        let trimmed = headerLine.trimmingCharacters(in: .whitespaces).lowercased()
        let firstToken = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" })
            .first
            .map(String.init) ?? ""
        switch firstToken {
        case "flowchart", "graph":
            return .flowchart
        case "mindmap":
            return .mindmap
        default:
            return nil
        }
    }

    // MARK: - Flowchart

    /// Matches edge connectors: -->, ---, -.->, ==>, <-->, -->|label|, --o / --x ends.
    private static let connectorRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<?(?:-\.+-*|--+|==+)(?:>|[ox](?=\s|$))?(?:\s*\|[^|]*\|)?"#
    )

    /// Inline-label forms ("A -- text --> B") rewritten to plain connectors
    /// before splitting, so the label text is not mistaken for a node.
    private static let inlineLabelRewrites: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"--\s+[^->][^>]*?\s+-->"#, "-->"),
            (#"-\.\s+[^.>][^>]*?\s+\.->"#, "-.->"),
            (#"==\s+[^=>][^>]*?\s+==>"#, "==>")
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    private static func parseFlowchart(_ lines: [String]) -> WikiGraph {
        var order: [String] = []
        var titles: [String: String] = [:]
        var labeled: Set<String> = []
        var types: [String: String] = [:]
        var edges: [(source: String, target: String)] = []
        var edgeKeys: Set<String> = []
        var subgraphStack: [String] = []

        func register(id: String, label: String, hasLabel: Bool) {
            let context = subgraphStack.last ?? "node"
            if titles[id] == nil {
                order.append(id)
                titles[id] = hasLabel ? label : id
                if hasLabel { labeled.insert(id) }
                types[id] = context
            } else {
                if hasLabel && !labeled.contains(id) {
                    titles[id] = label
                    labeled.insert(id)
                }
                if types[id] == "node" && context != "node" {
                    types[id] = context
                }
            }
        }

        let skipPrefixes = ["classdef", "class ", "style ", "click ", "linkstyle", "direction", "acctitle", "accdescr"]

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            while line.hasSuffix(";") {
                line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }

            let lower = line.lowercased()
            if skipPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            if lower == "end" {
                if !subgraphStack.isEmpty { subgraphStack.removeLast() }
                continue
            }
            if lower.hasPrefix("subgraph") {
                let raw = String(line.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
                subgraphStack.append(subgraphTitle(from: raw))
                continue
            }

            var normalized = line
            for (regex, template) in inlineLabelRewrites {
                normalized = regex.stringByReplacingMatches(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized),
                    withTemplate: template
                )
            }

            var groups: [[String]] = []
            for segment in splitOnConnectors(normalized) {
                var ids: [String] = []
                for piece in segment.components(separatedBy: "&") {
                    let spec = piece.trimmingCharacters(in: .whitespaces)
                    guard !spec.isEmpty,
                          let parsed = parseNodeSpec(spec) else { continue }
                    register(id: parsed.id, label: parsed.label, hasLabel: parsed.hasLabel)
                    ids.append(parsed.id)
                }
                if !ids.isEmpty { groups.append(ids) }
            }

            guard groups.count >= 2 else { continue }
            for i in 0..<(groups.count - 1) {
                for source in groups[i] {
                    for target in groups[i + 1] {
                        let key = source + "\u{1}" + target
                        if edgeKeys.insert(key).inserted {
                            edges.append((source, target))
                        }
                    }
                }
            }
        }

        let pages = order.map { id in
            WikiPage(
                id: id,
                title: titles[id] ?? id,
                type: types[id] ?? "node",
                tags: [],
                path: "",
                created: nil,
                updated: nil,
                confidence: nil,
                contested: false
            )
        }
        let links = edges.map { WikiLink(source: $0.source, target: $0.target, type: "edge") }
        return WikiGraph(pages: pages, links: links)
    }

    private static func subgraphTitle(from raw: String) -> String {
        guard !raw.isEmpty else { return "node" }
        if let parsed = parseNodeSpec(raw), parsed.hasLabel {
            return parsed.label
        }
        let stripped = stripQuotes(raw.trimmingCharacters(in: .whitespaces))
        return stripped.isEmpty ? "node" : stripped
    }

    private static func splitOnConnectors(_ line: String) -> [String] {
        guard let regex = connectorRegex else { return [line] }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [line] }

        var segments: [String] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                segments.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            segments.append(ns.substring(from: cursor))
        }
        return segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parses "id[Label]", "id((Label))", "id{Label}", "id>Label]", bare "id", etc.
    private static func parseNodeSpec(_ rawSpec: String) -> (id: String, label: String, hasLabel: Bool)? {
        var spec = rawSpec
        if let range = spec.range(of: ":::") {
            spec = String(spec[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !spec.isEmpty else { return nil }

        var idEnd = spec.startIndex
        while idEnd < spec.endIndex, isIdentChar(spec[idEnd]) {
            idEnd = spec.index(after: idEnd)
        }
        guard idEnd > spec.startIndex else { return nil }

        let id = String(spec[..<idEnd])
        let rest = String(spec[idEnd...]).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            return (id, id, false)
        }
        let label = cleanLabel(rest)
        return label.isEmpty ? (id, id, false) : (id, label, true)
    }

    private static func isIdentChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "."
    }

    /// Strips shape delimiters ([(), {}, >, /, \) and surrounding quotes.
    private static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while let f = s.first, "[({>/\\".contains(f) { s.removeFirst() }
        while let l = s.last, "])}/\\".contains(l) { s.removeLast() }
        return stripQuotes(s.trimmingCharacters(in: .whitespaces))
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last else { return s }
        if (f == "\"" && l == "\"") || (f == "'" && l == "'") || (f == "`" && l == "`") {
            return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    // MARK: - Mindmap

    private static func parseMindmap(_ lines: [String]) -> WikiGraph {
        struct TreeNode {
            let id: String
            let label: String
            let depth: Int
            var childCount = 0
        }

        var nodes: [TreeNode] = []
        var slugCounts: [String: Int] = [:]
        var edges: [(source: String, target: String)] = []
        var stack: [(indent: Int, index: Int)] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("%%") || trimmed.hasPrefix("::") { continue }

            let label = mindmapLabel(from: trimmed)
            guard !label.isEmpty else { continue }

            var slug = slugify(label)
            if slug.isEmpty { slug = "node" }
            let count = (slugCounts[slug] ?? 0) + 1
            slugCounts[slug] = count
            let id = count == 1 ? slug : "\(slug)-\(count)"

            let indent = indentWidth(of: rawLine)
            while let top = stack.last, top.indent >= indent {
                stack.removeLast()
            }
            if let parent = stack.last {
                nodes[parent.index].childCount += 1
                edges.append((nodes[parent.index].id, id))
            }
            nodes.append(TreeNode(id: id, label: label, depth: stack.count))
            stack.append((indent, nodes.count - 1))
        }

        let pages = nodes.map { node in
            WikiPage(
                id: node.id,
                title: node.label,
                type: node.depth == 0 ? "root" : (node.childCount > 0 ? "branch" : "leaf"),
                tags: [],
                path: "",
                created: nil,
                updated: nil,
                confidence: nil,
                contested: false
            )
        }
        let links = edges.map { WikiLink(source: $0.source, target: $0.target, type: "edge") }
        return WikiGraph(pages: pages, links: links)
    }

    /// Extracts the label from a mindmap line, stripping the optional id prefix
    /// and ()[]{} shape markers (e.g. "root((Central))" -> "Central").
    private static func mindmapLabel(from trimmed: String) -> String {
        var s = trimmed
        if let bracketIndex = s.firstIndex(where: { "([{".contains($0) }) {
            s = String(s[bracketIndex...])
        }
        while let f = s.first, "()[]{}".contains(f) { s.removeFirst() }
        while let l = s.last, "()[]{}".contains(l) { s.removeLast() }
        return stripQuotes(s.trimmingCharacters(in: .whitespaces))
    }

    private static func indentWidth(of line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    private static func slugify(_ s: String) -> String {
        var out = ""
        var lastWasDash = true
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
