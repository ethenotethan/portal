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
                imageUrl: resolvedMediaURL(d["image_url"]?.stringValue ?? ""), ts: d["ts"]?.stringValue ?? "",
                // Real publication date + approximation flag. This manual
                // construction bypasses FeedArticle's Codable init, so these
                // MUST be mapped here too — otherwise the card falls back to
                // ingest time and every item in a batch shows the same age.
                publishedTs: d["published_ts"]?.stringValue ?? "",
                validTimeApprox: d["valid_time_approx"]?.boolValue ?? false,
                videoUrl: resolvedMediaURL(d["video_url"]?.stringValue ?? ""),
                thumbnailUrl: resolvedMediaURL(d["thumbnail_url"]?.stringValue ?? ""),
                authorName: d["author_name"]?.stringValue,
                authorHandle: d["author_handle"]?.stringValue,
                authorAvatarUrl: d["author_avatar_url"]?.stringValue,
                metrics: Self.tweetMetrics(from: d["metrics"]?.dictionaryValue),
                replies: Self.feedReplies(from: d["replies"]?.arrayValue))
        }
        return FeedResponse(articles: articles, total: dict["total"]?.intValue ?? articles.count,
                           hasMore: dict["has_more"]?.boolValue ?? false)
    }

    /// Parse a tweet-metrics dict ({replies, reposts, likes, views}) — any
    /// subset decodes; all-missing yields nil so the card hides the counts.
    internal static func tweetMetrics(from dict: [String: AnyCodable]?) -> TweetMetrics? {
        guard let dict else { return nil }
        let m = TweetMetrics(
            replies: dict["replies"]?.intValue,
            reposts: dict["reposts"]?.intValue,
            likes: dict["likes"]?.intValue,
            views: dict["views"]?.intValue
        )
        return m.replies == nil && m.reposts == nil && m.likes == nil && m.views == nil ? nil : m
    }

    /// Parse an array of reply dicts ({author_name, author_handle, text, url}).
    internal static func feedReplies(from array: [AnyCodable]?) -> [FeedReply] {
        (array ?? []).compactMap { item in
            guard let d = item.dictionaryValue else { return nil }
            return FeedReply(
                id: d["id"]?.stringValue ?? UUID().uuidString,
                authorName: d["author_name"]?.stringValue ?? "",
                authorHandle: d["author_handle"]?.stringValue ?? "",
                text: d["text"]?.stringValue ?? "",
                url: d["url"]?.stringValue ?? ""
            )
        }
    }

    /// On-demand tweet detail for the comments UX: fresh metrics + the reply
    /// thread, fetched server-side via the gateway's X credentials
    /// (`feed.tweet_detail`). Gateways that predate the RPC return a
    /// method-not-found error — the card falls back to its syndication data.
    internal func feedTweetDetail(url: String) async throws -> FeedTweetDetail {
        let response = try await call("feed.tweet_detail", params: ["url": AnyCodable(url)])
        if let error = response.error {
            throw GatewayError.rpcError(
                JSONRPCError(code: error.code, message: error.message, data: error.data)
            )
        }
        guard let dict = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("feed.tweet_detail missing result")
        }
        return FeedTweetDetail(
            authorName: dict["author_name"]?.stringValue,
            authorHandle: dict["author_handle"]?.stringValue,
            authorAvatarURL: (dict["author_avatar_url"]?.stringValue).flatMap { URL(string: $0) },
            metrics: Self.tweetMetrics(from: dict["metrics"]?.dictionaryValue),
            replies: Self.feedReplies(from: dict["replies"]?.arrayValue)
        )
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
