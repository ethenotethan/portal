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
    let type: String        // e.g. "wikilink"

    init(source: String, target: String, type: String) {
        self.id = UUID()
        self.source = source
        self.target = target
        self.type = type
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
        var node = self
        for (i, part) in parts.enumerated() {
            let key = String(part)
            let currentPath = parts[0...i].joined(separator: "/")
            if node.children[key] == nil {
                node.children[key] = TaxonomyNode(name: key, path: currentPath, children: [:])
            }
            node = node.children[key]!
        }
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
