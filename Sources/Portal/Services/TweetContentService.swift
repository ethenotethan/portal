import Foundation

/// Tweet content resolved from X's public syndication endpoint
/// (`cdn.syndication.twimg.com/tweet-result`) — the same API the official
/// embed widget uses, no auth. Digest items often arrive as bare tweet URLs;
/// this resolves the actual tweet for the X-style card: full text with
/// display URLs, author avatar, real like/reply counts, media, and the
/// reply PARENT chain (inline) so threads render.
///
/// Not available here: repost/view counts and replies BELOW the tweet
/// (comments) — those still come from the backend's feed enrichment.
internal struct TweetEmbed: Equatable {
    internal let text: String
    internal let authorName: String?
    internal let authorHandle: String?
    internal let avatarURL: URL?
    internal let likeCount: Int?
    internal let replyCount: Int?
    internal let createdAt: String?
    internal let mediaURLs: [URL]
    /// The thread ABOVE this tweet (the reply parent chain), oldest first.
    /// Empty for a top-level tweet. Value-typed (no recursive nesting).
    internal let thread: [TweetEmbed]
    /// Canonical link for THIS tweet (thread rows click through to it).
    internal let url: String

    internal init(
        text: String,
        authorName: String? = nil,
        authorHandle: String? = nil,
        avatarURL: URL? = nil,
        likeCount: Int? = nil,
        replyCount: Int? = nil,
        createdAt: String? = nil,
        mediaURLs: [URL] = [],
        thread: [TweetEmbed] = [],
        url: String = ""
    ) {
        self.text = text
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.avatarURL = avatarURL
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.createdAt = createdAt
        self.mediaURLs = mediaURLs
        self.thread = thread
        self.url = url
    }
}

/// Extracts the tweet text from an oEmbed `html` blockquote (kept for the
/// oEmbed fallback path): `<p lang="en" dir="ltr">TEXT</p>` — tags stripped,
/// entities decoded.
internal enum TweetEmbedText {

    /// Pull the `<p>…</p>` body out of the embed HTML, convert `<br>` to
    /// newlines, strip every remaining tag, and decode HTML entities.
    internal static func extract(from html: String) -> String? {
        guard let openRange = html.range(of: "<p"),
              let tagEnd = html[openRange.lowerBound...].range(of: ">"),
              let closeRange = html.range(of: "</p>", range: tagEnd.upperBound..<html.endIndex) else {
            return nil
        }
        var text = String(html[tagEnd.upperBound..<closeRange.lowerBound])
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal entity decoder for tweet content: named entities first
    /// (&amp; LAST so double-escaped text decodes once), then numeric forms.
    internal static func decodeEntities(_ s: String) -> String {
        var text = s
        while let range = text.range(of: "&#(x?[0-9A-Fa-f]+);", options: .regularExpression) {
            let entity = text[range]
            let digits = entity.dropFirst(2).dropLast()
            let scalar: Unicode.Scalar?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                scalar = UInt32(digits.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
            } else {
                scalar = UInt32(digits).flatMap(Unicode.Scalar.init)
            }
            guard let scalar else { break }
            text.replaceSubrange(range, with: String(scalar))
        }
        let named: [(String, String)] = [
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ]
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Fetches and caches tweet embeds per URL (positive AND negative results,
/// so a failed fetch doesn't re-hit the network on every scroll pass).
/// Injected into TweetPostCard from the owning FeedView — one cache per
/// feed surface, swappable in tests.
internal actor TweetContentService {

    private var cache: [String: TweetEmbed?] = [:]
    private var inFlight: [String: Task<TweetEmbed?, Never>] = [:]
    private let session: URLSession

    internal init(session: URLSession = .shared) {
        self.session = session
    }

    /// True when this URL is worth a syndication fetch (X/Twitter status link).
    internal static func isTweetStatusURL(_ urlString: String) -> Bool {
        statusID(from: urlString) != nil
    }

    /// The numeric status id from an X/Twitter status URL, or nil.
    internal static func statusID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "x.com" || host == "twitter.com"
                || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com"),
              let range = url.path.range(of: "/status/") else {
            return nil
        }
        let id = url.path[range.upperBound...].prefix { $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    /// The syndication endpoint's token — loosely validated (garbage tokens
    /// pass), but we send the community-derived form for good hygiene.
    internal static func syndicationToken(for id: String) -> String {
        guard let num = Double(id) else { return "0" }
        let value = (num / 1e15) * Double.pi
        // Sub-1 values collapse to "0" (the documented token for early ids).
        guard value >= 1 else { return "0" }
        let intPart = Int(value.rounded(.down))
        var frac = value - Double(intPart)
        var out = String(intPart, radix: 36)
        for _ in 0..<10 where frac > 0 {
            frac *= 36
            let digit = Int(frac.rounded(.down))
            out += String(digit, radix: 36)
            frac -= Double(digit)
        }
        return out
    }

    /// Fetch the embed for a tweet URL; nil on any failure (cached).
    internal func embed(for tweetURL: String) async -> TweetEmbed? {
        if let cached = cache[tweetURL] { return cached }
        if let task = inFlight[tweetURL] { return await task.value }

        let task = Task<TweetEmbed?, Never> { [session] in
            guard let id = Self.statusID(from: tweetURL) else { return nil }
            var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")
            components?.queryItems = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "token", value: Self.syndicationToken(for: id)),
            ]
            guard let endpoint = components?.url else { return nil }
            do {
                let (data, response) = try await session.data(from: endpoint)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                return Self.parse(data: data, fallbackURL: tweetURL)
            } catch {
                return nil
            }
        }
        inFlight[tweetURL] = task
        let result = await task.value
        inFlight[tweetURL] = nil
        cache[tweetURL] = result
        return result
    }

    /// Map the syndication JSON to a TweetEmbed.
    internal static func parse(data: Data, fallbackURL: String) -> TweetEmbed? {
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            obj = parsed
        } catch {
            return nil
        }
        return parseTweet(obj, fallbackURL: fallbackURL, depth: 0)
    }

    /// Deepest a parent chain renders — long threads don't dominate the feed.
    private static let maxThreadDepth = 6

    /// Parse one Tweet object (recursing into `parent` for the thread chain).
    /// Defensive throughout: tombstones (deleted) and missing fields → nil.
    private static func parseTweet(_ obj: [String: Any], fallbackURL: String, depth: Int) -> TweetEmbed? {
        guard var text = obj["text"] as? String, !text.isEmpty else { return nil }

        // Media links hang off the end of the raw text — drop them (the media
        // itself renders below the body).
        if let media = obj["mediaDetails"] as? [[String: Any]] {
            for item in media {
                if let short = item["url"] as? String {
                    text = text.replacingOccurrences(of: short, with: "")
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Expand t.co short links to their display form via entities.urls.
        if let entities = obj["entities"] as? [String: Any],
           let urls = entities["urls"] as? [[String: Any]] {
            for entry in urls {
                if let short = entry["url"] as? String,
                   let display = entry["display_url"] as? String {
                    text = text.replacingOccurrences(of: short, with: display)
                }
            }
        }

        let user = obj["user"] as? [String: Any]
        let name = user?["name"] as? String
        let handle = user?["screen_name"] as? String
        let avatar = (user?["profile_image_url_https"] as? String).flatMap { URL(string: $0) }
        let mediaURLs = (obj["mediaDetails"] as? [[String: Any]] ?? [])
            .compactMap { ($0["media_url_https"] as? String).flatMap { URL(string: $0) } }

        // The reply parent chain, flattened oldest-first (T.thread = parent's
        // thread + parent).
        var thread: [TweetEmbed] = []
        if depth < maxThreadDepth, let parentObj = obj["parent"] as? [String: Any],
           let parent = parseTweet(parentObj, fallbackURL: "", depth: depth + 1) {
            thread = parent.thread + [parent]
        }

        let canonicalURL: String
        if let id = obj["id_str"] as? String, let handle, !handle.isEmpty {
            canonicalURL = "https://x.com/\(handle)/status/\(id)"
        } else {
            canonicalURL = fallbackURL
        }

        return TweetEmbed(
            text: text,
            authorName: name,
            authorHandle: handle,
            avatarURL: avatar,
            likeCount: obj["favorite_count"] as? Int,
            replyCount: obj["conversation_count"] as? Int,
            createdAt: obj["created_at"] as? String,
            mediaURLs: mediaURLs,
            thread: thread,
            url: canonicalURL
        )
    }
}
