import Foundation

/// A page in the LLM Wiki knowledge base.
struct WikiPage: Identifiable, Hashable, Codable {
    let id: String          // filename slug
    let title: String
    let type: String        // entity | concept | comparison | query | raw
    let tags: [String]
    let path: String        // relative path (e.g. "entities/dflash-mlx.md")
    let created: String?
    let updated: String?
    let confidence: String?
    let contested: Bool
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
}

/// Response structure for wiki.page RPC.
struct WikiPageContent: Hashable, Codable {
    var frontmatter: [String: String]
    var body: String
    var path: String
}
