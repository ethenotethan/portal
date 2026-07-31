import Testing
import Foundation
@testable import Portal

/// YouTube card support: video-id extraction across URL forms and the
/// oEmbed metadata mapping.
@Suite("YouTube embed")
internal struct YouTubeEmbedTests {

    @Test("Video id extracts from every common YouTube URL form")
    internal func videoIDForms() {
        #expect(YouTubeContentService.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeContentService.videoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeContentService.videoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeContentService.videoID(from: "https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeContentService.videoID(from: "https://m.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeContentService.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s") == "dQw4w9WgXcQ")
    }

    @Test("Non-video and non-YouTube URLs yield no id")
    internal func videoIDGuards() {
        #expect(YouTubeContentService.videoID(from: "https://www.youtube.com/") == nil)
        #expect(YouTubeContentService.videoID(from: "https://www.youtube.com/@channel") == nil)
        #expect(YouTubeContentService.videoID(from: "https://example.com/watch?v=abc") == nil)
        #expect(YouTubeContentService.videoID(from: "not a url") == nil)
    }

    @Test("FeedArticle.isYouTube gates the card route")
    internal func articleGate() {
        func item(_ url: String) -> FeedArticle {
            FeedArticle(id: "x", title: "", url: url, summary: "",
                        source: "blog", tags: [], imageUrl: "", ts: "")
        }
        #expect(item("https://www.youtube.com/watch?v=dQw4w9WgXcQ").isYouTube)
        #expect(item("https://youtu.be/dQw4w9WgXcQ").isYouTube)
        #expect(!item("https://x.com/jane/status/1").isYouTube)
        #expect(!item("https://example.com/article").isYouTube)
    }

    @Test("oEmbed JSON maps to title/channel/thumbnail")
    internal func parse() {
        let data = Data("""
        {"title": "Rick Astley - Never Gonna Give You Up",
         "author_name": "Rick Astley",
         "author_url": "https://www.youtube.com/@RickAstleyYT",
         "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"}
        """.utf8)
        let embed = YouTubeContentService.parse(data: data)
        #expect(embed?.title == "Rick Astley - Never Gonna Give You Up")
        #expect(embed?.channelName == "Rick Astley")
        #expect(embed?.channelURL == "https://www.youtube.com/@RickAstleyYT")
        #expect(embed?.thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(YouTubeContentService.parse(data: Data("junk".utf8)) == nil)
    }

    @Test("Player URL is the embed form with autoplay")
    internal func playerURL() {
        #expect(YouTubeContentService.playerURL(for: "abc")
                == "https://www.youtube.com/embed/abc?rel=0&autoplay=1")
        #expect(YouTubeContentService.playerURL(for: "abc", autoplay: false)
                == "https://www.youtube.com/embed/abc?rel=0")
    }
}
