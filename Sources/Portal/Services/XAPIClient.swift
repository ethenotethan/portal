import Foundation

/// Direct X API v2 calls with the user's OAuth token (see XAuthService) —
/// full-fidelity tweet detail for the feed card: metrics (replies, reposts,
/// likes, views), author + avatar, and the reply thread from conversation
/// search. Runs entirely app-side; nothing touches the gateway.
internal struct XAPIClient {

    private let auth: XAuthService
    private let session: URLSession

    internal init(auth: XAuthService, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    /// Tweet detail for a tweet URL: the tweet itself (metrics + author) and
    /// its top replies. Throws XAuthError when unsigned/expired, or
    /// XAPIError for endpoint failures.
    internal func tweetDetail(for tweetURL: String) async throws -> FeedTweetDetail {
        guard let id = TweetContentService.statusID(from: tweetURL) else {
            throw XAPIError.notATweetURL
        }
        let token = try await auth.validAccessToken()
        async let tweet = fetchTweet(id: id, token: token)
        async let replies = fetchReplies(conversationID: id, token: token)
        let (detail, thread) = try await (tweet, replies)
        return FeedTweetDetail(
            authorName: detail.authorName,
            authorHandle: detail.authorHandle,
            authorAvatarURL: detail.authorAvatarURL,
            metrics: detail.metrics,
            replies: thread
        )
    }

    // MARK: - Endpoints

    private struct TweetFields {
        var authorName: String?
        var authorHandle: String?
        var authorAvatarURL: URL?
        var metrics: TweetMetrics?
    }

    private func fetchTweet(id: String, token: String) async throws -> TweetFields {
        var components = URLComponents(string: "https://api.x.com/2/tweets/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "tweet.fields", value: "public_metrics,created_at"),
            URLQueryItem(name: "expansions", value: "author_id"),
            URLQueryItem(name: "user.fields", value: "name,username,profile_image_url"),
        ]
        let obj = try await get(components, token: token)
        let user = ((obj?["includes"] as? [String: Any])?["users"] as? [[String: Any]])?.first
        let metrics = (obj?["data"] as? [String: Any])?["public_metrics"] as? [String: Any]
        return TweetFields(
            authorName: user?["name"] as? String,
            authorHandle: user?["username"] as? String,
            authorAvatarURL: (user?["profile_image_url"] as? String).flatMap { URL(string: $0) },
            metrics: Self.mapMetrics(metrics)
        )
    }

    private func fetchReplies(conversationID: String, token: String) async throws -> [FeedReply] {
        var components = URLComponents(string: "https://api.x.com/2/tweets/search/recent")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "conversation_id:\(conversationID)"),
            URLQueryItem(name: "max_results", value: "10"),
            URLQueryItem(name: "tweet.fields", value: "author_id,created_at"),
            URLQueryItem(name: "expansions", value: "author_id"),
            URLQueryItem(name: "user.fields", value: "name,username,profile_image_url"),
        ]
        let obj = try await get(components, token: token)
        let users = ((obj?["includes"] as? [String: Any])?["users"] as? [[String: Any]]) ?? []
        let usersByID = Dictionary(
            users.compactMap { user -> (String, [String: Any])? in
                guard let id = user["id"] as? String else { return nil }
                return (id, user)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let tweets = (obj?["data"] as? [[String: Any]]) ?? []
        return tweets.compactMap { tweet in
            guard let id = tweet["id"] as? String, id != conversationID,
                  let text = tweet["text"] as? String else { return nil }
            let authorID = tweet["author_id"] as? String
            let user = authorID.flatMap { usersByID[$0] }
            let username = user?["username"] as? String ?? ""
            return FeedReply(
                id: id,
                authorName: user?["name"] as? String ?? username,
                authorHandle: username,
                text: text,
                url: "https://x.com/\(username)/status/\(id)"
            )
        }
    }

    // MARK: - Plumbing

    private func get(_ components: URLComponents?, token: String) async throws -> [String: Any]? {
        guard let url = components?.url else { throw XAPIError.badRequest }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XAPIError.badResponse }
        if http.statusCode == 401 {
            // One forced re-auth path: validAccessToken refreshes on demand,
            // so a 401 here means the account/app was revoked.
            throw XAuthError.endpointRejected("X rejected the token (401) — sign in again")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw XAPIError.httpError(http.statusCode)
        }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw XAPIError.badResponse
        }
    }

    /// public_metrics → TweetMetrics (all four counts the action bar shows).
    internal static func mapMetrics(_ metrics: [String: Any]?) -> TweetMetrics? {
        guard let metrics else { return nil }
        return TweetMetrics(
            replies: metrics["reply_count"] as? Int,
            reposts: metrics["retweet_count"] as? Int,
            likes: metrics["like_count"] as? Int,
            views: metrics["impression_count"] as? Int
        )
    }
}

internal enum XAPIError: LocalizedError {
    case notATweetURL
    case badRequest
    case badResponse
    case httpError(Int)

    internal var errorDescription: String? {
        switch self {
        case .notATweetURL: return "Not an X status URL"
        case .badRequest: return "Malformed X API request"
        case .badResponse: return "Bad response from the X API"
        case .httpError(let code): return "X API error (HTTP \(code))"
        }
    }
}
