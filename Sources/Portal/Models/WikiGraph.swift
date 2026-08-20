import Foundation

/// A page in the LLM Wiki knowledge base.
struct WikiPage: Identifiable, Hashable, Codable {
    let id: String          // filename slug
    let title: String
    let type: String        // entity | concept | comparison | query | raw
    let tags: [String]      // flat tags (backward compat)
    let path: String        // relative path (e.g. "entities/dflash-mlx.md")
    let created: String?
    let updated: String?
    let confidence: String?
    let contested: Bool

    /// Hierarchical taxonomy paths (e.g. ["ml/inference/speculative-decoding"])
    let tagPath: [String]

    /// Project management integration links
    let integrationLinks: [IntegrationLink]
}

/// A PM integration link (e.g. github:org/repo#123, linear:TEAM-456)
struct IntegrationLink: Identifiable, Hashable, Codable {
    var id: String { "\(prefix):\(identifier)" }
    let prefix: String      // "github", "linear", "notion", "obsidian", "slack"
    let identifier: String  // the rest after the colon
}

/// A link between two wiki pages.
struct WikiLink: Identifiable, Hashable, Codable {
    let id: UUID
    let source: String      // source page id
    let target: String      // target page id
    internal let type: String // relationship kind — "wikilink" for a plain link,
                            // else the predicate the gateway typed it with
                            // (e.g. "deployed_on", "implements"; SCHEMA §3.3)
    /// An explicit human-readable label when the gateway sends one; usually
    /// absent, in which case the relationship is derived from `type`. `nil` and
    /// `type == "wikilink"` together mean a plain link with nothing to render.
    internal let label: String?

    internal init(source: String, target: String, type: String, label: String? = nil) {
        self.id = UUID()
        self.source = source
        self.target = target
        self.type = type
        self.label = label
    }

    /// The relationship to draw on the edge: the explicit `label` if present,
    /// otherwise the predicate `type` prettified ("deployed_on" → "deployed
    /// on"). `nil` for a plain wikilink, which carries no relationship.
    internal var displayRelation: String? {
        if let label, !label.isEmpty { return label }
        guard type != "wikilink", !type.isEmpty else { return nil }
        return type.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

/// The full graph structure returned by wiki.scan.
struct WikiGraph: Hashable, Codable {
    let pages: [WikiPage]
    let links: [WikiLink]

    static let empty = WikiGraph(pages: [], links: [])

    /// All unique tagPath prefixes (for building category selectors)
    var tagPathTree: TaxonomyNode {
        var root = TaxonomyNode(name: "root", path: "", children: [:])
        for page in pages {
            for tp in page.tagPath {
                root.insert(path: tp)
            }
        }
        return root
    }
}

/// A node in the hierarchical taxonomy tree — built from tag_path values.
struct TaxonomyNode: Hashable, Codable {
    let name: String
    let path: String
    var children: [String: TaxonomyNode]

    mutating func insert(path: String) {
        let parts = path.split(separator: "/")
        guard let part = parts.first else { return }
        let key = String(part)
        let childPath = self.path.isEmpty ? key : "\(self.path)/\(key)"
        var child = children[key] ?? TaxonomyNode(name: key, path: childPath, children: [:])
        child.insert(path: parts.dropFirst().joined(separator: "/"))
        children[key] = child
    }

    /// Recursively flat list of all paths in the tree
    var flatPaths: [String] {
        var result = [path]
        for child in children.values.sorted(by: { $0.name < $1.name }) {
            result.append(contentsOf: child.flatPaths)
        }
        return result.filter { !$0.isEmpty }
    }
}

/// Response structure for wiki.page RPC.
struct WikiPageContent: Hashable, Codable {
    var frontmatter: [String: String]
    var body: String
    var path: String
}

/// Expanded link status returned by wiki.expand_links RPC.
struct ExpandedLinkStatus: Hashable, Codable {
    let key: String
    let type: String
    let status: String
    let title: String
    let url: String?
}
