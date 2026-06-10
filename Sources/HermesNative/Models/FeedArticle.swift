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

    /// Clean display-ready summary — strips markdown, HTML, and collapses whitespace.
    var displaySummary: String {
        var text = summary
        // Strip HTML tags
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.removeSubrange(range)
        }
        // Strip markdown links: [text](url) → text
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // Strip markdown formatting: **bold**, __bold__, *italic*, _italic_
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
        // Strip markdown headers: ##, ### etc
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Strip backtick code spans
        text = text.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Strip bullet markers
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        // Strip bare URLs
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Collapse whitespace
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
