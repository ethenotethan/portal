import Foundation

/// GitHub release metadata resolved from the public REST API
/// (`api.github.com/repos/{owner}/{repo}/releases/...`, no auth — 60 req/hr
/// per IP, per-release cached). The digest truncates summaries to 500 chars;
/// the API carries the FULL release notes, plus the tag, author, and publish
/// date for the release card.
internal struct GitHubReleaseEmbed: Equatable {
    internal let name: String?
    internal let tagName: String?
    internal let authorLogin: String?
    internal let authorAvatarURL: URL?
    internal let publishedAt: String?
    internal let htmlURL: String?
    /// Full release notes (markdown) — untruncated, unlike the digest's cap.
    internal let body: String?
}

/// Fetches and caches GitHub release metadata per release-page URL (positive
/// AND negative results). Injected from the owning FeedView — swappable in
/// tests.
internal actor GitHubContentService {

    private var cache: [String: GitHubReleaseEmbed?] = [:]
    private var inFlight: [String: Task<GitHubReleaseEmbed?, Never>] = [:]
    private let session: URLSession

    internal init(session: URLSession = .shared) {
        self.session = session
    }

    /// The API path for a GitHub release-page URL:
    /// `/releases` and `/releases/latest` → latest; `/releases/tag/{tag}` →
    /// that tag. Nil for non-GitHub or non-release URLs.
    internal static func apiPath(for urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0], repo = parts[1]
        guard parts.count >= 3, parts[2] == "releases" else { return nil }
        if parts.count == 3 || parts[3] == "latest" {
            return "/repos/\(owner)/\(repo)/releases/latest"
        }
        if parts[3] == "tag", parts.count >= 5, !parts[4].isEmpty {
            return "/repos/\(owner)/\(repo)/releases/tags/\(parts[4])"
        }
        return nil
    }

    /// The owner/repo pair from a GitHub URL (for the avatar fallback and
    /// display name) — independent of the release-page shape.
    internal static func ownerRepo(for urlString: String) -> (owner: String, repo: String)? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Fetch metadata for a release-page URL; nil on any failure (cached).
    internal func release(for urlString: String) async -> GitHubReleaseEmbed? {
        if let cached = cache[urlString] { return cached }
        if let task = inFlight[urlString] { return await task.value }

        let task = Task<GitHubReleaseEmbed?, Never> { [session] in
            guard let path = Self.apiPath(for: urlString),
                  let endpoint = URL(string: "https://api.github.com" + path) else { return nil }
            var request = URLRequest(url: endpoint)
            // GitHub requires a User-Agent on every API call.
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("portal-feed", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                return Self.parse(data: data)
            } catch {
                return nil
            }
        }
        inFlight[urlString] = task
        let result = await task.value
        inFlight[urlString] = nil
        cache[urlString] = result
        return result
    }

    /// Map the releases API JSON to a GitHubReleaseEmbed.
    internal static func parse(data: Data) -> GitHubReleaseEmbed? {
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            obj = parsed
        } catch {
            return nil
        }
        let author = obj["author"] as? [String: Any]
        return GitHubReleaseEmbed(
            name: obj["name"] as? String,
            tagName: obj["tag_name"] as? String,
            authorLogin: author?["login"] as? String,
            authorAvatarURL: (author?["avatar_url"] as? String).flatMap { URL(string: $0) },
            publishedAt: obj["published_at"] as? String,
            htmlURL: obj["html_url"] as? String,
            body: obj["body"] as? String
        )
    }
}
