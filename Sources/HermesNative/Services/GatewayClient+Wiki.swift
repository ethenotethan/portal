import Foundation

// MARK: - Wiki RPCs

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
            return WikiPage(
                id: d["id"]?.stringValue ?? "",
                title: d["title"]?.stringValue ?? "",
                type: d["type"]?.stringValue ?? "concept",
                tags: d["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                path: d["path"]?.stringValue ?? "",
                created: d["created"]?.stringValue,
                updated: d["updated"]?.stringValue,
                confidence: d["confidence"]?.stringValue,
                contested: d["contested"]?.boolValue ?? false
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
            throw GatewayError.invalidResponse("wiki.page missing result dictionary")
        }
        guard let pathStr = dict["path"]?.stringValue else {
            throw GatewayError.invalidResponse("wiki.page missing path in result")
        }
        return WikiPageContent(
            frontmatter: dict["frontmatter"]?.dictionaryValue?.compactMapValues { $0.stringValue } ?? [:],
            body: dict["body"]?.stringValue ?? "",
            path: pathStr
        )
    }
}
