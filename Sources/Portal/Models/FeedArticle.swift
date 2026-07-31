import Foundation

/// Read-only engagement counts for a tweet feed item (X-style action bar).
/// All fields optional: the backend only sends what it could fetch, and the
/// card hides a count (never a fake "0") when it's absent.
internal struct TweetMetrics: Codable, Hashable {
    internal let replies: Int?
    internal let reposts: Int?
    internal let likes: Int?
    internal let views: Int?

    /// X-style compact count: 1.2K, 3.4M, plain digits below 1000.
    internal static func compact(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value < 1_000_000 {
            let k = Double(value) / 1000
            return k < 10 ? String(format: "%.1fK", k) : "\(Int(k))K"
        }
        let m = Double(value) / 1_000_000
        return m < 10 ? String(format: "%.1fM", m) : "\(Int(m))M"
    }
}

/// A reply shown in the tweet card's read-only comments section.
internal struct FeedReply: Codable, Identifiable, Hashable {
    internal let id: String
    internal let authorName: String
    internal let authorHandle: String
    internal let text: String
    internal let url: String

    internal enum CodingKeys: String, CodingKey {
        case id, text, url
        case authorName = "author_name"
        case authorHandle = "author_handle"
    }

    internal init(id: String, authorName: String, authorHandle: String, text: String, url: String) {
        self.id = id
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.text = text
        self.url = url
    }

    internal init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

struct FeedArticle: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let summary: String
    let source: String
    let tags: [String]
    let imageUrl: String
    let ts: String
    /// Optional video media (e.g. digest_video source). Empty when absent.
    let videoUrl: String
    let thumbnailUrl: String

    // Tweet enrichment (optional, backend may omit — see feed_publish docs):
    /// Display name ("Jane Doe"), avatar URL, and engagement counts for the
    /// X-style card; replies power its read-only comments section.
    internal let authorName: String?
    internal let authorHandle: String?
    internal let authorAvatarUrl: String?
    internal let metrics: TweetMetrics?
    internal let replies: [FeedReply]

    /// True when this article carries a playable video.
    var hasVideo: Bool {
        !videoUrl.isEmpty
    }

    /// Returns a copy with a different `id`, used to de-collide duplicate IDs
    /// the backend may emit for a batch of title-less items (e.g. tweets).
    func withID(_ newID: String) -> FeedArticle {
        FeedArticle(id: newID, title: title, url: url, summary: summary,
                    source: source, tags: tags, imageUrl: imageUrl, ts: ts,
                    videoUrl: videoUrl, thumbnailUrl: thumbnailUrl,
                    authorName: authorName, authorHandle: authorHandle,
                    authorAvatarUrl: authorAvatarUrl, metrics: metrics, replies: replies)
    }

    init(id: String, title: String, url: String, summary: String, source: String,
         tags: [String], imageUrl: String, ts: String,
         videoUrl: String = "", thumbnailUrl: String = "",
         authorName: String? = nil, authorHandle: String? = nil,
         authorAvatarUrl: String? = nil, metrics: TweetMetrics? = nil,
         replies: [FeedReply] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.summary = summary
        self.source = source
        self.tags = tags
        self.imageUrl = imageUrl
        self.ts = ts
        self.videoUrl = videoUrl
        self.thumbnailUrl = thumbnailUrl
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarUrl = authorAvatarUrl
        self.metrics = metrics
        self.replies = replies
    }

    /// Clean summary ready for markdown rendering — strips HTML tags and
    /// image markup (shown separately as the hero image), preserves the
    /// block structure (paragraph breaks, list indentation) that the full
    /// markdown renderer needs.
    var displaySummary: String {
        var text = summary
        // Markdown images render as the hero image, not inline text
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        // Strip HTML tags
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.removeSubrange(range)
        }
        // Decode HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        // Normalize newlines: literal \n sequences, trailing per-line spaces,
        // runs of blank lines — but KEEP blank lines (paragraph breaks) and
        // leading indentation (nested lists / code blocks).
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact single-paragraph preview for the collapsed card.
    var previewSummary: String {
        return displaySummary
            .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n#{1,6}\s+"#, with: "\n", options: .regularExpression)
    }

    var isTwitter: Bool { source == "twitter" }

    /// The tweet's author/handle, when the backend encodes it as the title
    /// (tweets have no real headline). Shown as the card subtitle so you can
    /// see who posted without opening the link.
    var twitterAuthor: String? {
        guard isTwitter else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The handle used for the X-style card's header + avatar fallback:
    /// explicit `author_handle` when the backend sends it, else the title's
    /// handle form, else the handle in the tweet's own URL
    /// (`x.com/<handle>/status/…`) — normalized without the leading "@".
    /// Nil for non-tweets.
    internal var tweetHandle: String? {
        guard isTwitter else { return nil }
        if let h = authorHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !h.isEmpty {
            return h.hasPrefix("@") ? String(h.dropFirst()) : h
        }
        if let t = twitterAuthor {
            return t.hasPrefix("@") ? String(t.dropFirst()) : t
        }
        return Self.handleFromTweetURL(url)
    }

    /// Parse the author handle out of a tweet URL — the first path segment on
    /// an X/Twitter host, skipping non-user paths (home, explore, i, …).
    internal static func handleFromTweetURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "x.com" || host == "twitter.com"
                || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com") else {
            return nil
        }
        let blocked: Set<String> = [
            "home", "explore", "search", "settings", "messages",
            "notifications", "i", "hashtag", "compose", "intent",
        ]
        let first = url.pathComponents.first { $0 != "/" && !$0.isEmpty }
        guard let first, !blocked.contains(first.lowercased()) else { return nil }
        return first
    }

    /// Display name for the X-style card header: explicit `author_name`, else
    /// the handle (mirroring X's fallback when the API name is unavailable).
    internal var tweetAuthorDisplayName: String? {
        if let n = authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return tweetHandle
    }

    /// Avatar image URL for the X-style card: the backend's `author_avatar_url`
    /// when present, else the unavatar.io mirror for the handle.
    internal var tweetAvatarURL: URL? {
        if let a = authorAvatarUrl, let url = URL(string: a), url.scheme?.hasPrefix("http") == true {
            return url
        }
        guard let handle = tweetHandle, !handle.isEmpty else { return nil }
        return URL(string: "https://unavatar.io/twitter/\(handle)")
    }

    /// The text to show as the card body. Tweets often carry their content in
    /// `summary` with the handle in `title`; if `summary` is empty we fall back
    /// to the title so the card is never blank. Non-twitter sources keep using
    /// the summary as before.
    var cardBody: String {
        let body = previewSummary
        if body.isEmpty, isTwitter {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    /// Best available image: the pipeline's image_url, else the first image
    /// embedded in the raw summary (markdown or HTML — common in GitHub
    /// release notes, where screenshots are part of the body).
    var heroImageURL: URL? {
        if !imageUrl.isEmpty, let url = URL(string: imageUrl), url.scheme?.hasPrefix("http") == true {
            return url
        }
        let patterns = [
            #"!\[[^\]]*\]\((https?://[^)\s]+)"#,
            #"<img[^>]+src=["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            if let match = summary.range(of: pattern, options: .regularExpression) {
                let fragment = String(summary[match])
                if let urlRange = fragment.range(of: #"https?://[^)"'\s]+"#, options: .regularExpression),
                   let url = URL(string: String(fragment[urlRange])) {
                    return url
                }
            }
        }
        return nil
    }

    /// A small site icon for the card header — the article's own favicon,
    /// derived from its link's host via Google's favicon service. Standing in
    /// for the removed full-page screenshot: the site is now a small mark, not
    /// an arbitrary crop of its top. Nil when the article has no usable http
    /// host (e.g. a bare tweet), so the header falls back to `sourceIcon`.
    internal var faviconURL: URL? {
        guard let link = URL(string: url),
              link.scheme?.hasPrefix("http") == true,
              let host = link.host, !host.isEmpty else {
            return nil
        }
        return URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(host)")
    }

    var sourceIcon: String {
        switch source {
        case "arxiv":       return "doc.text.magnifyingglass"
        case "github":      return "chevron.left.slash.chevron.right"
        case "blog":        return "text.bubble"
        case "twitter":     return "bird"
        case "search":      return "magnifyingglass"
        default:            return "newspaper"
        }
    }

    var sourceLabel: String {
        switch source {
        case "arxiv":       return "Papers"
        case "github":      return "Releases"
        case "blog":        return "Blogs"
        case "twitter":     return "X/Twitter"
        default:            return source.capitalized
        }
    }

    var relativeTime: String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fmt.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else {
            return ""
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url, summary, source, tags, ts, metrics, replies
        case imageUrl = "image_url"
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case authorAvatarUrl = "author_avatar_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        summary = try c.decode(String.self, forKey: .summary)
        source = try c.decode(String.self, forKey: .source)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl) ?? ""
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        // Optional video fields — absent on non-video feed sources.
        videoUrl = try c.decodeIfPresent(String.self, forKey: .videoUrl) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl) ?? ""
        // Tweet enrichment — absent until the backend enriches twitter items.
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        authorAvatarUrl = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        metrics = try c.decodeIfPresent(TweetMetrics.self, forKey: .metrics)
        replies = try c.decodeIfPresent([FeedReply].self, forKey: .replies) ?? []
    }
}

struct FeedResponse: Codable {
    let articles: [FeedArticle]
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case articles, total
        case hasMore = "has_more"
    }
}

struct FeedSourcesResponse: Codable {
    let sources: [String: Int]
    let total: Int
}
