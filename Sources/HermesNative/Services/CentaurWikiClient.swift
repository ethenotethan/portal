import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "CentaurWikiClient")

// MARK: - WikiSource

/// The fetch surface the wiki views actually consume, extracted so a second
/// knowledge-base backend (Darkbloom's wiki-api — REST, public read-only)
/// can sit behind the same UI as the Hermes gateway's wiki.* RPCs.
@MainActor
protocol WikiSource: AnyObject {
    func fetchGraph() async throws -> WikiGraph
    func fetchPage(path: String) async throws -> WikiPageContent
    func search(query: String, limit: Int) async throws -> [WikiSearchResult]
}

struct WikiSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let snippet: String
    let type: String
}

// MARK: - Hermes conformance

/// GatewayClient already implements the underlying RPCs; adapt the shapes.
extension GatewayClient: WikiSource {
    func fetchGraph() async throws -> WikiGraph {
        try await wikiScan()
    }

    func fetchPage(path: String) async throws -> WikiPageContent {
        try await wikiPage(path: path)
    }

    func search(query: String, limit: Int) async throws -> [WikiSearchResult] {
        // Hermes has no search RPC; filter the scan client-side (the graph
        // is cached by the view model, so this stays cheap).
        let graph = try await wikiScan()
        let needle = query.lowercased()
        return graph.pages
            .filter { $0.title.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
            .prefix(limit)
            .map { WikiSearchResult(id: $0.path, title: $0.title, snippet: "", type: $0.type) }
    }
}

// MARK: - Centaur wiki-api client

/// Read-only client for Darkbloom's wiki-api (services/wiki-api): public
/// GET endpoints under /wiki/*. Bearer sent anyway — the endpoints are
/// unauthenticated today, but the header future-proofs a lockdown.
///
/// Beyond the WikiSource surface (graph/page/search), the client also serves
/// the Compendium ingestion timeline (CentaurWikiClient+Timeline.swift):
/// - `GET /wiki/timeline` — raw INPUT events that flowed into the knowledge
///   base (per-kind counts + directive attribution), and
/// - `GET /wiki/revisions-timeline` — the OUTPUT counterpart: page-edit
///   volume bucketed hour/day/week/month plus the pre-window cumulative
///   baseline for a "knowledge accrued" curve.
@MainActor
final class CentaurWikiClient: WikiSource {

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: Fetches

    /// /wiki/graph → WikiGraph. Node ids are document ids
    /// ("wiki:topic:glossary-mcp"); they double as page paths for fetchPage.
    func fetchGraph() async throws -> WikiGraph {
        let obj = try await getJSON("wiki/graph")
        let graph = Self.mapGraph(obj)
        log.info("centaur wiki graph: \(graph.pages.count) pages, \(graph.links.count) links")
        return graph
    }

    /// Pure mapping from the wiki-api /wiki/graph payload — separated for
    /// testability against captured live shapes.
    nonisolated static func mapGraph(_ obj: [String: Any]) -> WikiGraph {
        let nodes = (obj["nodes"] as? [[String: Any]]) ?? []
        let edges = (obj["edges"] as? [[String: Any]]) ?? []

        let pages: [WikiPage] = nodes.compactMap { n in
            guard let id = n["id"] as? String else { return nil }
            // "wiki:entity:person-greg" → tagPath ["entity"]; keeps the
            // taxonomy sidebar meaningful without a taxonomy endpoint.
            var kind = n["type"] as? String ?? id.split(separator: ":").dropFirst().first.map(String.init) ?? "topic"
            // Glossary pages are taxonomy DEFINITIONS — the docs frontend
            // renders them as their own class, but the API types them as
            // plain topics with a glossary- id prefix. Reclassify so they
            // get their own color/size and taxonomy bucket.
            if kind == "topic", id.hasPrefix("wiki:topic:glossary-") {
                kind = "glossary"
            }
            return WikiPage(
                id: id,
                title: n["title"] as? String ?? id,
                type: kind,
                tags: [],
                path: id,                       // document id IS the fetch path
                created: nil,
                updated: n["updated_at"] as? String,
                confidence: nil,
                contested: false,
                tagPath: [kind],
                integrationLinks: []
            )
        }
        let links: [WikiLink] = edges.compactMap { e in
            guard let source = e["source"] as? String,
                  let target = e["target"] as? String else { return nil }
            return WikiLink(source: source, target: target, type: "wikilink")
        }
        return WikiGraph(pages: pages, links: links)
    }

    /// /wiki/page/{document_id} → WikiPageContent. Non-body fields become
    /// frontmatter so WikiPageDetailView's metadata section renders.
    func fetchPage(path: String) async throws -> WikiPageContent {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let obj = try await getJSON("wiki/page/\(encoded)")
        var frontmatter: [String: String] = [:]
        for (key, value) in obj where key != "body" {
            frontmatter[key] = "\(value)"
        }
        return WikiPageContent(
            frontmatter: frontmatter,
            body: obj["body"] as? String ?? "",
            path: path
        )
    }

    /// /wiki/search?q= → ranked results with server-side snippets.
    func search(query: String, limit: Int) async throws -> [WikiSearchResult] {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let queryString = components.percentEncodedQuery ?? ""
        let obj = try await getJSON("wiki/search?\(queryString)")
        let results = (obj["results"] as? [[String: Any]]) ?? []
        return results.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return WikiSearchResult(
                id: id,
                title: r["title"] as? String ?? id,
                snippet: r["snippet"] as? String ?? "",
                type: r["type"] as? String ?? "topic"
            )
        }
    }

    // MARK: Plumbing

    /// Internal (not private) so CentaurWikiClient+Timeline.swift shares it.
    func getJSON(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw GatewayError.invalidResponse("bad wiki path: \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayError.invalidResponse("non-HTTP response from wiki-api")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayError.rpcError(JSONRPCError(
                code: http.statusCode,
                message: "wiki-api GET \(path): HTTP \(http.statusCode)"
            ))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayError.invalidResponse("wiki-api \(path): not a JSON object")
        }
        return obj
    }
}
