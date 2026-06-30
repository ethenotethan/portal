import Foundation

// MARK: - Wiki RPCs

/// Lightweight wiki descriptor returned by wiki.list RPC.
struct WikiInfo: Codable, Hashable {
    let name: String
    let path: String
}

/// Taxonomy tree returned by wiki.taxonomy RPC.
struct WikiTaxonomyResponse: Codable {
    let taxonomy: [String: AnyCodable]
    let flatPaths: [String]
}

// MARK: - Changesets (Timeline)

/// A single recorded change to a wiki page, returned by `wiki.changesets`.
/// See docs/api/wiki-changesets.md in hermes-agent.
struct WikiChangeset: Identifiable, Hashable {
    let id: String
    let timestamp: String        // ISO 8601 UTC
    let action: Action           // create | update | archive | delete
    let page: String             // relative path, e.g. "entities/llama-cpp.md"
    let title: String
    let type: String             // entity | concept | comparison | ...
    let summary: String
    let linesAdded: Int
    let linesRemoved: Int
    let trigger: Trigger
    let source: String           // raw source path ("" if none)
    let gitCommit: String        // short git hash ("" if none)

    enum Action: String {
        case create, update, archive, delete
        case unknown

        init(raw: String) { self = Action(rawValue: raw) ?? .unknown }

        var icon: String {
            switch self {
            case .create: return "plus.circle.fill"
            case .update: return "pencil.circle.fill"
            case .archive: return "archivebox.fill"
            case .delete: return "trash.circle.fill"
            case .unknown: return "circle.fill"
            }
        }

        var label: String {
            switch self {
            case .unknown: return "change"
            default: return rawValue
            }
        }
    }

    enum Trigger: String {
        case ingest, query, lint
        case processInbox = "process-inbox"
        case manual
        case unknown

        init(raw: String) { self = Trigger(rawValue: raw) ?? .unknown }

        var label: String {
            switch self {
            case .processInbox: return "inbox"
            case .unknown: return "—"
            default: return rawValue
            }
        }
    }

    /// Parsed `Date` from the ISO 8601 timestamp (nil if unparseable).
    /// A fresh formatter is created per call to stay `Sendable`-safe; timeline
    /// parsing volume is low (≤200 rows/page) so the cost is negligible.
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

/// Response envelope for `wiki.changesets`, including pagination cursor.
struct WikiChangesetsPage {
    let changesets: [WikiChangeset]
    let total: Int
    let limit: Int
    let offset: Int

    /// Whether more changesets exist beyond this page.
    var hasMore: Bool { offset + changesets.count < total }
}

@MainActor
extension GatewayClient {

    /// Scan the wiki directory and return the full graph structure.
    /// - Parameters:
    ///   - wiki: Wiki name from ~/.hermes/wikis.yaml (e.g. "d-inference").
    ///     Omit to use the server-side default wiki.
    func wikiScan(wiki: String? = nil) async throws -> WikiGraph {
        var params: [String: AnyCodable] = [:]
        if let w = wiki {
            params["wiki"] = AnyCodable(w)
        }
        let response = try await call("wiki.scan", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue,
              let pagesArray = dict["pages"]?.arrayValue,
              let linksArray = dict["links"]?.arrayValue else {
            throw GatewayError.invalidResponse("wiki.scan missing pages/links arrays")
        }

        let pages: [WikiPage] = pagesArray.compactMap { item -> WikiPage? in
            guard let d = item.dictionaryValue else { return nil }

            // Parse tag_path (hierarchical) — new field
            let tagPath: [String] = d["tag_path"]?.arrayValue?.compactMap { $0.stringValue } ?? []

            // Parse integration_links — new field
            let integrationLinks: [IntegrationLink] = (d["integration_links"]?.arrayValue ?? []).compactMap { linkItem -> IntegrationLink? in
                guard let linkStr = linkItem.stringValue, linkStr.contains(":") else { return nil }
                let parts = linkStr.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return IntegrationLink(
                    prefix: String(parts[0]),
                    identifier: String(parts[1])
                )
            }

            return WikiPage(
                id: d["id"]?.stringValue ?? "",
                title: d["title"]?.stringValue ?? "",
                type: d["type"]?.stringValue ?? "concept",
                tags: d["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                path: d["path"]?.stringValue ?? "",
                created: d["created"]?.stringValue,
                updated: d["updated"]?.stringValue,
                confidence: d["confidence"]?.stringValue,
                contested: d["contested"]?.boolValue ?? false,
                tagPath: tagPath,
                integrationLinks: integrationLinks
            )
        }

        let links: [WikiLink] = linksArray.compactMap { item -> WikiLink? in
            guard let d = item.dictionaryValue,
                  let source = d["source"]?.stringValue,
                  let target = d["target"]?.stringValue else { return nil }
            return WikiLink(
                source: source,
                target: target,
                type: d["type"]?.stringValue ?? "wikilink"
            )
        }

        return WikiGraph(pages: pages, links: links)
    }

    /// Read a single wiki page by relative path.
    /// - Parameters:
    ///   - path: Relative path within the wiki (e.g. "entities/dflash-mlx.md").
    ///   - wiki: Wiki name from ~/.hermes/wikis.yaml (e.g. "d-inference").
    ///     Omit to use the server-side default wiki.
    func wikiPage(path: String, wiki: String? = nil) async throws -> WikiPageContent {
        var params: [String: AnyCodable] = ["path": AnyCodable(path)]
        if let w = wiki {
            params["wiki"] = AnyCodable(w)
        }
        let response = try await call("wiki.page", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("wiki.page missing result")
        }
        let frontmatter = dict["frontmatter"]?.dictionaryValue?.mapValues { $0.stringValue ?? "" } ?? [:]
        let body = dict["body"]?.stringValue ?? ""
        let pagePath = dict["path"]?.stringValue ?? path

        return WikiPageContent(frontmatter: frontmatter, body: body, path: pagePath)
    }

    /// Fetch the hierarchical taxonomy tree from the gateway.
    /// - Parameter wiki: Wiki name from ~/.hermes/wikis.yaml (optional).
    /// - Returns: Flat list of all valid taxonomy paths.
    func wikiTaxonomy(wiki: String? = nil) async throws -> [String] {
        var params: [String: AnyCodable] = [:]
        if let w = wiki {
            params["wiki"] = AnyCodable(w)
        }
        let response = try await call("wiki.taxonomy", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue,
              let flatPaths = dict["flat_paths"]?.arrayValue?.compactMap({ $0.stringValue }) else {
            throw GatewayError.invalidResponse("wiki.taxonomy missing flat_paths array")
        }
        return flatPaths
    }

    /// Expand integration links for a wiki page into live status objects.
    /// - Parameters:
    ///   - slug: The page slug (e.g. "dflash-mlx").
    ///   - wiki: Wiki name from ~/.hermes/wikis.yaml (optional).
    /// - Returns: Dictionary mapping link strings to expanded status.
    func wikiExpandLinks(slug: String, wiki: String? = nil) async throws -> [String: ExpandedLinkStatus] {
        var params: [String: AnyCodable] = ["slug": AnyCodable(slug)]
        if let w = wiki {
            params["wiki"] = AnyCodable(w)
        }
        let response = try await call("wiki.expand_links", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let resultDict = response.result?.dictionaryValue else {
            return [:]
        }
        var expanded: [String: ExpandedLinkStatus] = [:]
        for (key, value) in resultDict {
            guard let entry = value.dictionaryValue else { continue }
            expanded[key] = ExpandedLinkStatus(
                key: key,
                type: entry["type"]?.stringValue ?? "unknown",
                status: entry["status"]?.stringValue ?? "unknown",
                title: entry["title"]?.stringValue ?? key,
                url: entry["url"]?.stringValue
            )
        }
        return expanded
    }

    /// List available wikis from the gateway.
    func wikiList() async throws -> [WikiInfo] {
        let response = try await call("wiki.list", params: [:])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue,
              let wikisArray = dict["wikis"]?.arrayValue else {
            throw GatewayError.invalidResponse("wiki.list missing wikis array")
        }
        return wikisArray.compactMap { item -> WikiInfo? in
            guard let d = item.dictionaryValue,
                  let name = d["name"]?.stringValue,
                  let path = d["path"]?.stringValue else { return nil }
            return WikiInfo(name: name, path: path)
        }
    }

    /// Fetch the wiki edit timeline (changesets), newest first.
    ///
    /// All parameters are optional — omit everything for the full timeline.
    /// - Parameters:
    ///   - wiki: Wiki name (omit for default).
    ///   - page: Filter to a single page's history (e.g. "entities/llama-cpp.md").
    ///   - action: Filter by change type ("create" | "update" | "archive" | "delete").
    ///   - trigger: Filter by what caused the change.
    ///   - since: Only changesets at/after this ISO 8601 instant.
    ///   - until: Only changesets at/before this ISO 8601 instant.
    ///   - limit: Page size (default 50, max 200).
    ///   - offset: Pagination offset.
    func wikiChangesets(
        wiki: String? = nil,
        page: String? = nil,
        action: String? = nil,
        trigger: String? = nil,
        since: String? = nil,
        until: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> WikiChangesetsPage {
        var params: [String: AnyCodable] = [
            "limit": AnyCodable(limit),
            "offset": AnyCodable(offset),
        ]
        if let wiki { params["wiki"] = AnyCodable(wiki) }
        if let page { params["page"] = AnyCodable(page) }
        if let action { params["action"] = AnyCodable(action) }
        if let trigger { params["trigger"] = AnyCodable(trigger) }
        if let since { params["since"] = AnyCodable(since) }
        if let until { params["until"] = AnyCodable(until) }

        let response = try await call("wiki.changesets", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue,
              let changesetsArray = dict["changesets"]?.arrayValue else {
            throw GatewayError.invalidResponse("wiki.changesets missing changesets array")
        }

        let changesets: [WikiChangeset] = changesetsArray.compactMap { item -> WikiChangeset? in
            guard let d = item.dictionaryValue,
                  let id = d["id"]?.stringValue else { return nil }
            let stats = d["diff_stats"]?.dictionaryValue
            return WikiChangeset(
                id: id,
                timestamp: d["timestamp"]?.stringValue ?? "",
                action: WikiChangeset.Action(raw: d["action"]?.stringValue ?? ""),
                page: d["page"]?.stringValue ?? "",
                title: d["title"]?.stringValue ?? "",
                type: d["type"]?.stringValue ?? "",
                summary: d["summary"]?.stringValue ?? "",
                linesAdded: stats?["lines_added"]?.intValue ?? 0,
                linesRemoved: stats?["lines_removed"]?.intValue ?? 0,
                trigger: WikiChangeset.Trigger(raw: d["trigger"]?.stringValue ?? ""),
                source: d["source"]?.stringValue ?? "",
                gitCommit: d["git_commit"]?.stringValue ?? ""
            )
        }

        return WikiChangesetsPage(
            changesets: changesets,
            total: dict["total"]?.intValue ?? changesets.count,
            limit: dict["limit"]?.intValue ?? limit,
            offset: dict["offset"]?.intValue ?? offset
        )
    }
}
