import Testing
import Foundation
@testable import Portal

/// Tweet-card model behavior: handle normalization, avatar fallback chain,
/// compact metric formatting, and backward-compatible decoding of the
/// optional enrichment fields (author, metrics, replies).
@Suite("Feed tweet model")
internal struct FeedTweetModelTests {

    private func article(
        title: String = "@janedoe",
        authorHandle: String? = nil,
        authorName: String? = nil,
        authorAvatarUrl: String? = nil
    ) -> FeedArticle {
        FeedArticle(
            id: "t1", title: title, url: "https://x.com/janedoe/status/1",
            summary: "hello", source: "twitter", tags: [], imageUrl: "", ts: "",
            authorName: authorName, authorHandle: authorHandle,
            authorAvatarUrl: authorAvatarUrl
        )
    }

    @Test("Explicit handle wins and loses its @; title handle is the fallback")
    internal func handleNormalization() {
        #expect(article(authorHandle: "@real").tweetHandle == "real")
        #expect(article(authorHandle: "real").tweetHandle == "real")
        #expect(article(title: "@titlehandle").tweetHandle == "titlehandle")
        #expect(article(title: "titlehandle").tweetHandle == "titlehandle")
        #expect(article(title: "  ").tweetHandle == nil)   // blank title → no handle
    }

    @Test("Display name prefers author_name, else falls back to the handle")
    internal func displayName() {
        #expect(article(authorName: "Jane Doe").tweetAuthorDisplayName == "Jane Doe")
        #expect(article(authorHandle: "janedoe").tweetAuthorDisplayName == "janedoe")
    }

    @Test("Avatar prefers the backend URL, then unavatar by handle, else nil")
    internal func avatarFallback() {
        #expect(article(authorAvatarUrl: "https://cdn.x.com/a.jpg").tweetAvatarURL?.absoluteString
                == "https://cdn.x.com/a.jpg")
        #expect(article(authorHandle: "janedoe").tweetAvatarURL?.absoluteString
                == "https://unavatar.io/twitter/janedoe")
        let noHandle = article(title: "  ", authorHandle: " ")
        #expect(noHandle.tweetAvatarURL == nil)
    }

    @Test("Compact metric formatting matches X's style")
    internal func compactMetrics() {
        #expect(TweetMetrics.compact(0) == "0")
        #expect(TweetMetrics.compact(999) == "999")
        #expect(TweetMetrics.compact(1200) == "1.2K")
        #expect(TweetMetrics.compact(12_300) == "12K")
        #expect(TweetMetrics.compact(3_400_000) == "3.4M")
        #expect(TweetMetrics.compact(22_000_000) == "22M")
    }

    @Test("Enrichment fields decode when present, default when absent")
    internal func decoding() throws {
        let json = Data("""
        {"id": "t1", "title": "@janedoe", "url": "https://x.com/janedoe/status/1",
         "summary": "hi", "source": "twitter",
         "author_name": "Jane Doe", "author_handle": "janedoe",
         "author_avatar_url": "https://cdn.x.com/a.jpg",
         "metrics": {"replies": 12, "reposts": 48, "likes": 1204, "views": 22000},
         "replies": [{"author_name": "Dev", "author_handle": "dev",
                      "text": "nice", "url": "https://x.com/dev/status/2"}]}
        """.utf8)
        let a = try JSONDecoder().decode(FeedArticle.self, from: json)
        #expect(a.authorName == "Jane Doe")
        #expect(a.tweetHandle == "janedoe")
        #expect(a.metrics?.likes == 1204)
        #expect(a.metrics?.views == 22_000)
        #expect(a.replies.count == 1)
        #expect(a.replies.first?.text == "nice")

        // Older payloads without the enrichment keys still decode.
        let legacy = Data("""
        {"id": "t2", "title": "@x", "url": "https://x.com/x/status/2",
         "summary": "old", "source": "twitter"}
        """.utf8)
        let b = try JSONDecoder().decode(FeedArticle.self, from: legacy)
        #expect(b.metrics == nil)
        #expect(b.replies.isEmpty)
        #expect(b.authorAvatarUrl == nil)
    }
}
