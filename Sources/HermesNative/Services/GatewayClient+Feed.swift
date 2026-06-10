import Foundation

@MainActor
extension GatewayClient {
    func feedGet(sources: [String]? = nil, since: String? = nil,
                 limit: Int = 50, offset: Int = 0) async throws -> FeedResponse {
        var params: [String: AnyCodable] = [:]
        if let s = sources { params["sources"] = .array(s.map(AnyCodable.init)) }
        if let d = since { params["since"] = AnyCodable(d) }
        params["limit"] = AnyCodable(limit)
        params["offset"] = AnyCodable(offset)

        let response = try await call("feed.get", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue,
              let articlesArray = dict["articles"]?.arrayValue else {
            throw GatewayError.invalidResponse("feed.get missing articles array")
        }
        let articles: [FeedArticle] = articlesArray.compactMap { item -> FeedArticle? in
            guard let d = item.dictionaryValue, let id = d["id"]?.stringValue,
                  let title = d["title"]?.stringValue, let source = d["source"]?.stringValue else { return nil }
            return FeedArticle(id: id, title: title,
                url: d["url"]?.stringValue ?? "", summary: d["summary"]?.stringValue ?? "",
                source: source, tags: d["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                imageUrl: d["image_url"]?.stringValue ?? "", ts: d["ts"]?.stringValue ?? "")
        }
        return FeedResponse(articles: articles, total: dict["total"]?.intValue ?? articles.count,
                           hasMore: dict["has_more"]?.boolValue ?? false)
    }

    func feedSources() async throws -> FeedSourcesResponse {
        let response = try await call("feed.sources", params: [:])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("feed.sources missing result")
        }
        let sources: [String: Int] = dict["sources"]?.dictionaryValue?.compactMapValues { $0.intValue } ?? [:]
        return FeedSourcesResponse(sources: sources, total: dict["total"]?.intValue ?? 0)
    }
}
