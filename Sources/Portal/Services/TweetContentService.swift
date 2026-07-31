import Foundation

/// Tweet content + author info fetched from X's public oEmbed endpoint
/// (`publish.twitter.com/oembed`) — no auth required. Digest items often
/// arrive as bare tweet URLs with no text; this resolves the actual tweet
/// contents for the X-style card. Engagement metrics are NOT available from
/// oEmbed (those come from the backend's feed enrichment instead).
internal struct TweetEmbed: Equatable {
    internal let text: String
    internal let authorName: String?
    internal let authorHandle: String?
}

/// Extracts the tweet text from the oEmbed `html` blockquote:
/// `<p lang="en" dir="ltr">TEXT</p>&mdash; author (@handle) <a>date</a>`.
/// Pure and allocation-cheap — the only transformation the card needs.
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
        // Numeric entities: &#123; and &#x1F600;
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

    /// True when this URL is worth an oEmbed fetch (an X/Twitter status link).
    internal static func isTweetStatusURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "x.com" || host == "twitter.com"
                || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com") else {
            return false
        }
        return url.path.contains("/status/")
    }

    /// Fetch the embed for a tweet URL; nil on any failure (cached).
    internal func embed(for tweetURL: String) async -> TweetEmbed? {
        if let cached = cache[tweetURL] { return cached }
        if let task = inFlight[tweetURL] { return await task.value }

        let task = Task<TweetEmbed?, Never> { [session] in
            var components = URLComponents(string: "https://publish.twitter.com/oembed")
            components?.queryItems = [
                URLQueryItem(name: "url", value: tweetURL),
                URLQueryItem(name: "dnt", value: "true"),
            ]
            guard let endpoint = components?.url else { return nil }
            do {
                let (data, response) = try await session.data(from: endpoint)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                return Self.parse(data: data)
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

    /// Map the oEmbed JSON to a TweetEmbed.
    private static func parse(data: Data) -> TweetEmbed? {
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            obj = parsed
        } catch {
            return nil
        }
        guard let html = obj["html"] as? String,
              let text = TweetEmbedText.extract(from: html), !text.isEmpty else {
            return nil
        }
        let authorName = obj["author_name"] as? String
        let handle = (obj["author_url"] as? String)
            .flatMap { URL(string: $0)?.pathComponents.last(where: { $0 != "/" }) }
        return TweetEmbed(text: text, authorName: authorName, authorHandle: handle)
    }
}
