import Testing
import Foundation
@testable import Portal

/// GitHub release card support: release-URL parsing, owner/repo extraction,
/// and the API metadata mapping.
@Suite("GitHub release embed")
internal struct GitHubReleaseEmbedTests {

    @Test("Release URLs map to API paths (latest, tag)")
    internal func apiPaths() {
        #expect(GitHubContentService.apiPath(for: "https://github.com/o/r/releases")
                == "/repos/o/r/releases/latest")
        #expect(GitHubContentService.apiPath(for: "https://github.com/o/r/releases/latest")
                == "/repos/o/r/releases/latest")
        #expect(GitHubContentService.apiPath(for: "https://github.com/o/r/releases/tag/v1.2.3")
                == "/repos/o/r/releases/tags/v1.2.3")
        #expect(GitHubContentService.apiPath(for: "https://github.com/ggml-org/llama.cpp/releases/tag/b10213")
                == "/repos/ggml-org/llama.cpp/releases/tags/b10213")
    }

    @Test("Non-release and non-GitHub URLs yield no API path")
    internal func apiPathGuards() {
        #expect(GitHubContentService.apiPath(for: "https://github.com/o/r") == nil)
        #expect(GitHubContentService.apiPath(for: "https://github.com/o/r/pull/1") == nil)
        #expect(GitHubContentService.apiPath(for: "https://gitlab.com/o/r/releases") == nil)
        #expect(GitHubContentService.apiPath(for: "not a url") == nil)
    }

    @Test("owner/repo extracts for the avatar fallback")
    internal func ownerRepo() {
        let or = GitHubContentService.ownerRepo(for: "https://github.com/ggml-org/llama.cpp/releases/tag/b10213")
        #expect(or?.owner == "ggml-org")
        #expect(or?.repo == "llama.cpp")
        #expect(GitHubContentService.ownerRepo(for: "https://github.com/o") == nil)
        #expect(GitHubContentService.ownerRepo(for: "https://example.com/o/r") == nil)
    }

    @Test("API JSON maps to name/tag/author/date/html_url/body")
    internal func parse() {
        let data = Data("""
        {"name": "b10213", "tag_name": "b10213",
         "published_at": "2026-07-31T20:10:00Z",
         "html_url": "https://github.com/ggml-org/llama.cpp/releases/tag/b10213",
         "body": "Support rotated kv cache quant (#26180)",
         "author": {"login": "github-actions[bot]",
                    "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4"}}
        """.utf8)
        let embed = GitHubContentService.parse(data: data)
        #expect(embed?.name == "b10213")
        #expect(embed?.tagName == "b10213")
        #expect(embed?.authorLogin == "github-actions[bot]")
        #expect(embed?.authorAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/in/15368?v=4")
        #expect(embed?.publishedAt == "2026-07-31T20:10:00Z")
        #expect(embed?.htmlURL == "https://github.com/ggml-org/llama.cpp/releases/tag/b10213")
        #expect(embed?.body?.contains("rotated kv cache") == true)
        #expect(GitHubContentService.parse(data: Data("junk".utf8)) == nil)
    }
}
