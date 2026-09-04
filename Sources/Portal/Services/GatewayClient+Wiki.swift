import Foundation

// MARK: - Wiki RPCs

/// Lightweight wiki descriptor returned by wiki.list RPC.
struct WikiInfo: Codable, Hashable {
    let name: String
    let path: String
}

/// Per-wiki proper-noun policy returned by `wiki.glossary`.
internal struct WikiGlossary: Codable, Equatable, Sendable {
    internal enum Mode: String, Codable, CaseIterable, Sendable {
        case canonicalize
        case strict

        internal var title: String {
            switch self {
            case .canonicalize: "Canonicalize"
            case .strict: "Strict"
            }
        }
    }

    internal struct ProperNoun: Codable, Equatable, Identifiable, Sendable {
        internal var canonical: String
        internal var aliases: [String]
        internal var description: String?

        internal var id: String { canonical }
    }

    internal var enabled: Bool
    internal var version: Int
    internal var mode: Mode
    internal var properNouns: [ProperNoun]
    internal var revision: String

    private enum CodingKeys: String, CodingKey {
        case enabled, version, mode, revision
        case properNouns = "proper_nouns"
    }
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
    /// The wire value verbatim, NOT a closed enum. What a trigger *means* is
    /// declared by a `type: event-type` wiki page and resolved through
    /// `WikiEventTypeRegistry`, so a wiki can add an ingestion source without
    /// an app release. The enum this replaces folded every unrecognized value
    /// into one indistinguishable bucket.
    internal let trigger: String
    /// Legacy single raw source path ("" if none). Superseded by `provenance`,
    /// which folds this in — kept because a gateway predating provenance still
    /// sends it and nothing else on the wire carries the same information.
    internal let source: String
    /// Which ingestion events caused this change — `.unknown` when nobody
    /// recorded any. See `WikiProvenance`: unknown is not a claim that no
    /// cause exists.
    internal let provenance: WikiProvenance
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

// MARK: - Event log

/// Response envelope for `wiki.events`, including pagination cursor.
///
/// The server also echoes back the effective `limit`; it's dropped rather than
/// stored, because nothing reads it and `hasMore` answers the only question a
/// caller currently asks. A paginating caller adds it back in one line.
internal struct WikiEventLogPage {
    internal let events: [WikiTimelineEvent]
    internal let total: Int
    internal let offset: Int

    /// Whether more events exist beyond this page. Counted from what actually
    /// arrived rather than from the page size, so a short page (server cap,
    /// dropped rows) doesn't claim there's more when there isn't.
    internal var hasMore: Bool { offset + events.count < total }
}

/// Thrown by `wikiUpdate` when the server rejects a write because the page
/// changed since the client read it (spec: HTTP-style 409 — typically an
/// agent edit landing mid-edit). Carries the server's latest stored page
/// when the server included `data.latest`, so the caller can offer
/// reload/merge without a re-fetch.
internal struct WikiUpdateConflict: Error {
    internal let latest: WikiPageContent?
}

/// The glossary changed after the editor loaded it.
internal struct WikiGlossaryConflict: Error {}

/// Narrow source seam for the glossary editor. Keeping the view on this
/// protocol makes its loading and conflict behavior testable without a socket.
@MainActor
internal protocol WikiGlossarySource: AnyObject {
    func wikiGlossary(wiki: String?) async throws -> WikiGlossary
    func wikiGlossaryUpdate(
        wiki: String?,
        version: Int,
        mode: WikiGlossary.Mode,
        properNouns: [WikiGlossary.ProperNoun],
        ifMatch: String?
    ) async throws -> WikiGlossary
}

@MainActor
extension GatewayClient: WikiGlossarySource {

    /// Fetch the proper-noun policy for one configured wiki.
    internal func wikiGlossary(wiki: String? = nil) async throws -> WikiGlossary {
        var params: [String: AnyCodable] = [:]
        if let wiki { params["wiki"] = AnyCodable(wiki) }
        let response = try await call("wiki.glossary", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message, data: error.data))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("wiki.glossary missing result")
        }
        return try Self.decodeGlossary(result, method: "wiki.glossary")
    }

    /// Replace a wiki's proper-noun policy with optimistic concurrency.
    internal func wikiGlossaryUpdate(
        wiki: String? = nil,
        version: Int,
        mode: WikiGlossary.Mode,
        properNouns: [WikiGlossary.ProperNoun],
        ifMatch: String? = nil
    ) async throws -> WikiGlossary {
        let response = try await call(
            "wiki.glossary.update",
            params: Self.wikiGlossaryUpdateParams(
                wiki: wiki,
                version: version,
                mode: mode,
                properNouns: properNouns,
                ifMatch: ifMatch
            )
        )
        if let error = response.error {
            if error.code == 409 { throw WikiGlossaryConflict() }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message, data: error.data))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("wiki.glossary.update missing result")
        }
        return try Self.decodeGlossary(result, method: "wiki.glossary.update")
    }

    /// Kept pure so the exact mutation contract can be asserted without a socket.
    internal static func wikiGlossaryUpdateParams(
        wiki: String?,
        version: Int,
        mode: WikiGlossary.Mode,
        properNouns: [WikiGlossary.ProperNoun],
        ifMatch: String?
    ) -> [String: AnyCodable] {
        let terms: [AnyCodable] = properNouns.map { term in
            var value: [String: AnyCodable] = [
                "canonical": AnyCodable(term.canonical),
                "aliases": .array(term.aliases.map(AnyCodable.init)),
            ]
            if let description = term.description, !description.isEmpty {
                value["description"] = AnyCodable(description)
            }
            return .dictionary(value)
        }
        var params: [String: AnyCodable] = [
            "version": AnyCodable(version),
            "mode": AnyCodable(mode.rawValue),
            "proper_nouns": .array(terms),
        ]
        if let wiki { params["wiki"] = AnyCodable(wiki) }
        if let ifMatch { params["if_match"] = AnyCodable(ifMatch) }
        return params
    }

    private static func decodeGlossary(_ value: AnyCodable, method: String) throws -> WikiGlossary {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(WikiGlossary.self, from: data)
        } catch {
            throw GatewayError.invalidResponse("\(method) returned an invalid glossary: \(error.localizedDescription)")
        }
    }

    /// Scan the wiki directory and return the full graph structure.
    /// - Parameters:
    ///   - wiki: Wiki name from ~/.hermes/wikis.yaml (e.g. "d-inference").
    ///     Omit to use the server-side default wiki.
    func wikiScan(wiki: String? = nil) async throws -> WikiGraph {
        var params: [String: AnyCodable] = [:]
        if let w = wiki {
            params["wiki"] = AnyCodable(w)
        }
        // A full wiki scan is one un-paginated round-trip; without a ceiling a
        // slow or wedged gateway leaves the pane on "Loading…" indefinitely.
        // Fail fast so the surface can show a real error with a retry.
        let response = try await call("wiki.scan", params: params, timeout: 30)
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
                type: d["type"]?.stringValue ?? "wikilink",
                label: d["label"]?.stringValue
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
        return Self.pageContent(from: dict, fallbackPath: path)
    }

    /// Write a wiki page (the one mutating RPC on the wiki surface — see
    /// docs/rpc-reference.md `wiki.update` semantics).
    ///
    /// Full-replace write with optimistic concurrency: pass the `updated`
    /// value read at load time as `ifMatch`; the server rejects the write
    /// with a 409 when the page changed underneath (typically an agent
    /// edit), surfaced here as `WikiUpdateConflict`. `force` is the
    /// user-confirmed "save anyway" path past a conflict.
    ///
    /// - Parameters:
    ///   - path: Page path relative to the wiki root.
    ///   - body: FULL replacement markdown body (no patch mode).
    ///   - frontmatter: When non-nil, REPLACES the entire frontmatter block.
    ///   - ifMatch: Optimistic-concurrency precondition (`updated` at read).
    ///   - force: Bypass the `ifMatch` precondition.
    ///   - wiki: Wiki name (omit for the server-side default).
    /// - Returns: The stored page including the server's fresh `updated`.
    internal func wikiUpdate(
        path: String,
        body: String,
        frontmatter: [String: String]? = nil,
        ifMatch: String? = nil,
        force: Bool = false,
        wiki: String? = nil
    ) async throws -> WikiPageContent {
        var params: [String: AnyCodable] = [
            "path": AnyCodable(path),
            "body": AnyCodable(body),
            "force": AnyCodable(force),
        ]
        if let frontmatter {
            params["frontmatter"] = .dictionary(frontmatter.mapValues { AnyCodable($0) })
        }
        if let ifMatch { params["if_match"] = AnyCodable(ifMatch) }
        if let w = wiki { params["wiki"] = AnyCodable(w) }

        let response = try await call("wiki.update", params: params)
        if let error = response.error {
            if error.code == 409 {
                throw WikiUpdateConflict(
                    latest: error.data?.dictionaryValue?["latest"]?.dictionaryValue
                        .map { Self.pageContent(from: $0, fallbackPath: path) }
                )
            }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message, data: error.data))
        }
        guard let dict = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("wiki.update missing result")
        }
        return Self.pageContent(from: dict, fallbackPath: path)
    }

    /// Shared parser for the wiki.page / wiki.update result shape
    /// (`frontmatter` + `body` + `path`).
    private static func pageContent(from dict: [String: AnyCodable], fallbackPath: String) -> WikiPageContent {
        let frontmatter = dict["frontmatter"]?.dictionaryValue?.mapValues { $0.stringValue ?? "" } ?? [:]
        let body = dict["body"]?.stringValue ?? ""
        let pagePath = dict["path"]?.stringValue ?? fallbackPath
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
                trigger: d["trigger"]?.stringValue ?? "",
                source: d["source"]?.stringValue ?? "",
                // A gateway predating provenance omits the key entirely but may
                // still carry a legacy `source`; an enforcing one sends [] for
                // "unrecorded" and has already folded `source` into the keys.
                // Both collapse to .unknown when genuinely empty, which is why
                // the client never has to know which gateway it's talking to.
                provenance: WikiProvenance.decode(
                    d[WikiProvenance.wireKey]?.arrayValue?.compactMap(\.stringValue),
                    legacySource: d["source"]?.stringValue ?? ""
                ),
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

    /// Fetch the ingestion event log — what flowed in and what it changed.
    ///
    /// Gateway-side this is a join, not new storage: files under `raw/` are the
    /// events, and the changeset index records which events caused which page
    /// writes (hermes-agent#44). So each event reports the changesets it
    /// produced, giving the event → changeset → page edge without a second
    /// call; `WikiChangeset.provenance` already carries the reverse.
    ///
    /// - Parameters:
    ///   - wiki: Wiki name (omit for the server-side default).
    ///   - kind: Filter by event kind. Kinds are declared by `type: event-type`
    ///     wiki pages, so this is an open vocabulary — pass a wire value, not a
    ///     case of some enum.
    ///   - since: Only events at/after this ISO 8601 instant.
    ///   - until: Only events at/before this ISO 8601 instant.
    ///   - limit: Page size (default 200, server caps at 1000).
    ///   - offset: Pagination offset.
    internal func wikiEvents(
        wiki: String? = nil,
        kind: String? = nil,
        since: String? = nil,
        until: String? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> WikiEventLogPage {
        var params: [String: AnyCodable] = [
            "limit": AnyCodable(limit),
            "offset": AnyCodable(offset),
        ]
        if let wiki { params["wiki"] = AnyCodable(wiki) }
        if let kind { params["kind"] = AnyCodable(kind) }
        if let since { params["since"] = AnyCodable(since) }
        if let until { params["until"] = AnyCodable(until) }

        let response = try await call("wiki.events", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue,
              let eventsArray = dict["events"]?.arrayValue else {
            throw GatewayError.invalidResponse("wiki.events missing events array")
        }

        let events = eventsArray.compactMap { Self.eventLogEntry(from: $0) }
        return WikiEventLogPage(
            events: events,
            total: dict["total"]?.intValue ?? events.count,
            offset: dict["offset"]?.intValue ?? offset
        )
    }

    /// Map one `wiki.events` entry onto the shared event row.
    ///
    /// The gateway reports a single `timestamp` (frontmatter `ingested`, or the
    /// file mtime when that's missing). There is no separate real-world event
    /// time on this backend, so both time fields get it.
    ///
    /// `time_estimated` says the gateway fell back to the file's mtime. That's a
    /// real observation but not the event's own time — `git clone` rewrites every
    /// mtime — so it earns the estimated-time mark. An `ingested` value that the
    /// wiki actually recorded does not: the diamond means "this time was
    /// inferred", and claiming that for a recorded time is a false warning.
    nonisolated internal static func eventLogEntry(from item: AnyCodable) -> WikiTimelineEvent? {
        guard let d = item.dictionaryValue,
              let key = d["key"]?.stringValue, !key.isEmpty else { return nil }
        let timestamp = WikiTimelineDecoding.parseDate(d["timestamp"]?.stringValue)
        let changesets: [WikiEventChangesetRef] = (d["changesets"]?.arrayValue ?? [])
            .compactMap { entry -> WikiEventChangesetRef? in
                guard let c = entry.dictionaryValue,
                      let id = c["id"]?.stringValue, !id.isEmpty else { return nil }
                return WikiEventChangesetRef(
                    id: id,
                    page: c["page"]?.stringValue ?? "",
                    title: c["title"]?.stringValue ?? "",
                    action: c["action"]?.stringValue ?? "",
                    timestamp: WikiTimelineDecoding.parseDate(c["timestamp"]?.stringValue)
                )
            }
        // An event with no title falls back to the key's own short label
        // rather than rendering an empty row.
        let title = d["title"]?.stringValue ?? ""
        return WikiTimelineEvent(
            sourceKey: key,
            kindRaw: d["kind"]?.stringValue ?? "",
            label: title.isEmpty ? WikiEventRef(key: key).shortLabel : title,
            url: d["source_url"]?.stringValue ?? "",
            occurredAt: timestamp,
            ingestedAt: timestamp,
            // Absent on a gateway that predates the flag, which is the same
            // thing as "not estimated" as far as anything downstream can tell.
            eventTimeEstimated: d["time_estimated"]?.boolValue ?? false,
            actorSlackID: nil,
            actorName: nil,
            directiveBody: nil,
            directiveExcerpt: nil,
            targetPages: nil,
            directiveStatus: nil,
            resultingRevisionIDs: nil,
            changesets: changesets,
            sha256: d["sha256"]?.stringValue ?? ""
        )
    }

    /// Fetch the unified git diff for a single changeset (timeline detail).
    /// Throws `.rpcError` with code 5057 when the wiki wasn't git-initialized
    /// at capture time — surface the message rather than treating it as fatal.
    func wikiChangesetDiff(id: String, wiki: String? = nil) async throws -> String {
        var params: [String: AnyCodable] = ["id": AnyCodable(id)]
        if let wiki { params["wiki"] = AnyCodable(wiki) }
        let response = try await call("wiki.changeset_diff", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let diff = response.result?.dictionaryValue?["diff"]?.stringValue else {
            throw GatewayError.invalidResponse("wiki.changeset_diff missing diff")
        }
        return diff
    }
}
