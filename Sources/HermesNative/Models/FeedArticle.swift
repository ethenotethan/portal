import Foundation

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

    /// True when this article carries a playable video.
    var hasVideo: Bool {
        !videoUrl.isEmpty
    }

    /// Returns a copy with a different `id`, used to de-collide duplicate IDs
    /// the backend may emit for a batch of title-less items (e.g. tweets).
    func withID(_ newID: String) -> FeedArticle {
        FeedArticle(id: newID, title: title, url: url, summary: summary,
                    source: source, tags: tags, imageUrl: imageUrl, ts: ts,
                    videoUrl: videoUrl, thumbnailUrl: thumbnailUrl)
    }

    init(id: String, title: String, url: String, summary: String, source: String,
         tags: [String], imageUrl: String, ts: String,
         videoUrl: String = "", thumbnailUrl: String = "") {
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
        let text = displaySummary
            .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n#{1,6}\s+"#, with: "\n", options: .regularExpression)
        return text
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
        case id, title, url, summary, source, tags, ts
        case imageUrl = "image_url"
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
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
