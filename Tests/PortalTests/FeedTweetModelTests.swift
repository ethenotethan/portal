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
        url: String = "https://x.com/janedoe/status/1",
        authorHandle: String? = nil,
        authorName: String? = nil,
        authorAvatarUrl: String? = nil
    ) -> FeedArticle {
        FeedArticle(
            id: "t1", title: title, url: url,
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
        // Blank title and no explicit handle: falls to the URL's handle
        // (x.com host), or nil when the URL isn't a tweet link.
        #expect(article(title: "  ").tweetHandle == "janedoe")
        #expect(article(title: "  ", url: "https://example.com/x").tweetHandle == nil)
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
        let noHandle = article(title: "  ", url: "https://example.com/x", authorHandle: " ")
        #expect(noHandle.tweetAvatarURL == nil)
    }

    @Test("Handle falls back to the tweet URL's first path segment")
    internal func handleFromURL() {
        #expect(FeedArticle.handleFromTweetURL("https://x.com/janedoe/status/123") == "janedoe")
        #expect(FeedArticle.handleFromTweetURL("https://twitter.com/janedoe/status/123") == "janedoe")
        #expect(FeedArticle.handleFromTweetURL("https://mobile.twitter.com/janedoe") == "janedoe")
        #expect(FeedArticle.handleFromTweetURL("https://x.com/home") == nil)          // non-user path
        #expect(FeedArticle.handleFromTweetURL("https://x.com/explore") == nil)
        #expect(FeedArticle.handleFromTweetURL("https://example.com/janedoe") == nil) // wrong host
        #expect(FeedArticle.handleFromTweetURL("not a url") == nil)

        // End-to-end: a URL-only item still renders a name + avatar, not "Unknown".
        let urlOnly = FeedArticle(
            id: "t9", title: "", url: "https://x.com/janedoe/status/123",
            summary: "", source: "twitter", tags: [], imageUrl: "", ts: ""
        )
        #expect(urlOnly.tweetHandle == "janedoe")
        #expect(urlOnly.tweetAuthorDisplayName == "janedoe")
        #expect(urlOnly.tweetAvatarURL?.absoluteString == "https://unavatar.io/twitter/janedoe")
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
    internal func decoding() throws {        let json = Data("""
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

@Suite("Feed article summary presentation")
internal struct FeedArticleSummaryTests {

    private func article(summary: String) -> FeedArticle {
        FeedArticle(
            id: "article-1", title: "Launch", url: "https://example.com/launch",
            summary: summary, source: "blog", tags: [], imageUrl: "", ts: ""
        )
    }

    @Test("Display summary removes duplicate markup while preserving document structure")
    internal func displaySummarySanitizesMarkup() {
        let summary = [
            "![hero](https://example.com/hero.png)",
            "<h2>Launch &amp; Learn</h2>   ",
            "- first\\n  - nested",
            "",
            "",
            "Use &lt;tags&gt; &quot;carefully&quot; &#39;now&#39;",
        ].joined(separator: "\n")

        #expect(
            article(summary: summary).displaySummary
                == "Launch & Learn\n- first\n  - nested\n\nUse <tags> \"carefully\" 'now'"
        )
    }

    @Test("Preview summary removes heading markers without flattening paragraphs")
    internal func previewSummaryRemovesHeadingMarkers() {
        let summary = "# Headline\n\n## Details\nBody"
        #expect(article(summary: summary).previewSummary == "Headline\n\nDetails\nBody")
    }
}

// The oEmbed fallback: extracting tweet text + author from the public
// embed HTML, and the status-URL gate that decides when to fetch.
@Suite("Tweet embed")
internal struct TweetEmbedTests {

    @Test("Extracts the tweet text from the oEmbed blockquote")
    internal func extractText() {
        let html = """
        <blockquote class="twitter-tweet" data-dnt="true"><p lang="en" dir="ltr">just setting up my twttr</p>&mdash; jack (@jack) <a href="https://x.com/jack/status/20">March 21, 2006</a></blockquote>
        <script async src="https://platform.x.com/widgets.js" charset="utf-8"></script>
        """
        #expect(TweetEmbedText.extract(from: html) == "just setting up my twttr")
    }

    @Test("Links drop their tags but keep inner text; <br> becomes newlines")
    internal func extractWithLinks() {
        let html = #"<p lang="en" dir="ltr">Ship it <a href="https://t.co/x">github.com/org/repo</a><br>second line</p> tail"#
        #expect(TweetEmbedText.extract(from: html) == "Ship it github.com/org/repo\nsecond line")
    }

    @Test("Entities decode: named, numeric, and &amp; last")
    internal func entities() {
        #expect(TweetEmbedText.decodeEntities("a &amp; b &mdash; c &#38; d") == "a & b — c & d")
        #expect(TweetEmbedText.decodeEntities("&lt;tag&gt; &#39;q&#39;") == "<tag> 'q'")
        #expect(TweetEmbedText.decodeEntities("&#x1F680;") == "\u{1F680}")
    }

    @Test("Only X/Twitter status URLs qualify for an oEmbed fetch")
    internal func statusURLGate() {
        #expect(TweetContentService.isTweetStatusURL("https://x.com/jane/status/123"))
        #expect(TweetContentService.isTweetStatusURL("https://twitter.com/jane/status/123"))
        #expect(!TweetContentService.isTweetStatusURL("https://x.com/jane"))
        #expect(!TweetContentService.isTweetStatusURL("https://x.com/home"))
        #expect(!TweetContentService.isTweetStatusURL("https://example.com/jane/status/1"))
        #expect(!TweetContentService.isTweetStatusURL("not a url"))
    }
}

// Syndication (tweet-result) parsing: full text with display URLs, media
// link stripping, author/avatar, real counts, and the flattened thread chain.
@Suite("Tweet syndication")
internal struct TweetSyndicationTests {

    private func fixture() -> Data {
        Data("""
        {"__typename": "Tweet",
         "favorite_count": 1204, "conversation_count": 48,
         "created_at": "2026-07-01T12:00:00.000Z",
         "id_str": "100", "lang": "en",
         "text": "Part 2: shipped the explorer https://t.co/abc https://t.co/pic1",
         "entities": {"urls": [{"url": "https://t.co/abc",
                                "display_url": "github.com/org/repo",
                                "expanded_url": "https://github.com/org/repo"}]},
         "mediaDetails": [{"url": "https://t.co/pic1",
                           "media_url_https": "https://pbs.twimg.com/media/1.jpg",
                           "type": "photo"}],
         "user": {"name": "Jane Doe", "screen_name": "janedoe",
                  "profile_image_url_https": "https://pbs.twimg.com/img/avatar.jpg"},
         "parent": {"__typename": "Tweet", "id_str": "99",
                    "text": "Part 1: building it",
                    "conversation_count": 3, "favorite_count": 10,
                    "created_at": "2026-07-01T11:00:00.000Z",
                    "user": {"name": "Jane Doe", "screen_name": "janedoe",
                             "profile_image_url_https": "https://pbs.twimg.com/img/avatar.jpg"}}}
        """.utf8)
    }

    @Test("Parses text, author, avatar, counts, media, and the thread chain")
    internal func parse() {
        let embed = TweetContentService.parse(data: fixture(), fallbackURL: "https://x.com/janedoe/status/100")
        #expect(embed != nil)
        #expect(embed?.text == "Part 2: shipped the explorer github.com/org/repo")
        #expect(embed?.authorName == "Jane Doe")
        #expect(embed?.authorHandle == "janedoe")
        #expect(embed?.avatarURL?.absoluteString == "https://pbs.twimg.com/img/avatar.jpg")
        #expect(embed?.likeCount == 1204)
        #expect(embed?.replyCount == 48)
        #expect(embed?.mediaURLs.first?.absoluteString == "https://pbs.twimg.com/media/1.jpg")
        #expect(embed?.url == "https://x.com/janedoe/status/100")
        // Parent flattened oldest-first, with its own canonical URL.
        #expect(embed?.thread.count == 1)
        #expect(embed?.thread.first?.text == "Part 1: building it")
        #expect(embed?.thread.first?.url == "https://x.com/janedoe/status/99")
    }

    @Test("Tombstones and junk parse to nil; status ids extract from URLs")
    internal func guards() {
        let tombstone = Data("{\"__typename\": \"Tweet\", \"tombstone\": {}}".utf8)
        #expect(TweetContentService.parse(data: tombstone, fallbackURL: "") == nil)
        #expect(TweetContentService.parse(data: Data("not json".utf8), fallbackURL: "") == nil)
        #expect(TweetContentService.statusID(from: "https://x.com/jane/status/123") == "123")
        #expect(TweetContentService.statusID(from: "https://twitter.com/jane/status/45?s=20") == "45")
        #expect(TweetContentService.statusID(from: "https://x.com/jane") == nil)
        #expect(TweetContentService.syndicationToken(for: "20") == "0")
    }
}
