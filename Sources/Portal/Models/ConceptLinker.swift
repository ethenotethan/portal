import Foundation

/// Deterministically links a reasoning beat to the tool calls that act on the
/// same CONCEPT — drawn as faint edges on the timeline so "I should check the
/// status MD file" visibly connects to the `read status.md` call. No model:
/// when a reasoning beat and a tool call share a SALIENT token (a file path,
/// an identifier, a quoted term — never a stopword), that's a link. It would
/// rather miss a link than draw a spurious one, so only high-signal tokens
/// count.
///
/// Same philosophy as SharedEntityExtractor (#246): matching, not inference.
internal struct ConceptLink: Identifiable {
    /// The reasoning-beat node id.
    internal let reasoningID: String
    /// The tool-call node id it shares a concept with.
    internal let toolID: String
    /// The shared salient token (for tooltip / debugging).
    internal let concept: String

    internal var id: String { "\(reasoningID)~\(toolID)~\(concept)" }
}

internal enum ConceptLinker {

    /// Find concept links across a turn's nodes: reasoning beats ↔ tool calls
    /// that share a salient token. At most one link per (beat, tool) pair —
    /// the first shared concept found — so the overlay stays legible.
    internal static func link(nodes: [ThoughtGraphNode]) -> [ConceptLink] {
        // Precompute salient token sets per node.
        var tokensByID: [String: Set<String>] = [:]
        var reasoning: [ThoughtGraphNode] = []
        var tools: [ThoughtGraphNode] = []
        for node in nodes {
            tokensByID[node.id] = salientTokens(in: node)
            if node.category == .reasoning {
                reasoning.append(node)
            } else if !node.isAgent {
                tools.append(node)
            }
        }

        var links: [ConceptLink] = []
        for beat in reasoning {
            guard let beatTokens = tokensByID[beat.id], !beatTokens.isEmpty else { continue }
            for tool in tools {
                guard let toolTokens = tokensByID[tool.id] else { continue }
                // One shared salient token wins (deterministic: smallest).
                if let shared = beatTokens.intersection(toolTokens).min() {
                    links.append(ConceptLink(reasoningID: beat.id, toolID: tool.id, concept: shared))
                }
            }
        }
        return links
    }

    // MARK: - Salient token extraction

    /// Generic words that carry no linking signal — a beat and a tool both
    /// saying "file" or "check" is not a shared concept.
    private static let stopwords: Set<String> = [
        "file", "files", "read", "reading", "write", "writing", "check", "checking",
        "search", "searching", "look", "looking", "find", "finding", "the", "and",
        "for", "with", "this", "that", "into", "from", "run", "running", "get",
        "getting", "list", "listing", "open", "opening", "call", "calling", "using",
        "status", "data", "code", "test", "tests", "update", "updating", "create",
        "creating", "edit", "editing", "path", "name", "value", "text", "content",
    ]

    /// High-signal tokens from a node's text: file basenames (without
    /// extension), code identifiers (camelCase / snake_case / dotted), and
    /// quoted terms. Lowercased; stopwords and short fragments dropped.
    internal static func salientTokens(in node: ThoughtGraphNode) -> Set<String> {
        var text = node.context ?? ""
        if let summary = node.summary { text += " " + summary }
        guard !text.isEmpty else { return [] }

        var tokens: Set<String> = []

        // File basenames from any confident path (Client.swift → "client").
        if let path = node.confidentFilePath {
            let base = path.split(separator: "/").last.map(String.init) ?? path
            let stem = base.split(separator: ".").first.map(String.init) ?? base
            addToken(stem, to: &tokens)
        }

        // Word-ish tokens: identifiers, dotted names, hyphenated names.
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for m in Self.tokenRegex.matches(in: text, range: range) {
            addToken(ns.substring(with: m.range), to: &tokens)
        }
        return tokens
    }

    private static func addToken(_ raw: String, to set: inout Set<String>) {
        let t = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        // Keep tokens that are specific: ≥4 chars and not a stopword, OR any
        // multi-word compound (camelCase/snake/dotted) which is inherently
        // specific even if short.
        let isCompound = raw.contains("_") || raw.contains(".")
            || raw.rangeOfCharacter(from: .uppercaseLetters) != nil
                && raw.rangeOfCharacter(from: .lowercaseLetters) != nil
        guard !t.isEmpty, !stopwords.contains(t) else { return }
        guard isCompound || t.count >= 4 else { return }
        set.insert(t)
    }

    private static let tokenRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_.\-]{2,}"#)
        } catch {
            assertionFailure("ConceptLinker token regex failed to compile")
            return NSRegularExpression()
        }
    }()
}
