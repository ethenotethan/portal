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

    /// Clean summary ready for MarkdownText rendering — strips HTML, preserves markdown.
    var displaySummary: String {
        var text = summary
        // Strip HTML tags
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.removeSubrange(range)
        }
        // Decode HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        // Normalize newlines and whitespace
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
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
