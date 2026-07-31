import Foundation

/// YouTube video metadata resolved from YouTube's public oEmbed endpoint
/// (`youtube.com/oembed`, no auth): the video's title, channel, and hq
/// thumbnail. Digest items often carry only a bare watch URL.
internal struct YouTubeEmbed: Equatable {
    internal let title: String?
    internal let channelName: String?
    internal let channelURL: String?
    internal let thumbnailURL: URL?
}

/// Fetches and caches YouTube oEmbed metadata per video id (positive AND
/// negative results, so a failed fetch doesn't re-hit the network on every
/// scroll pass). Injected from the owning FeedView — swappable in tests.
internal actor YouTubeContentService {

    private var cache: [String: YouTubeEmbed?] = [:]
    private var inFlight: [String: Task<YouTubeEmbed?, Never>] = [:]
    private let session: URLSession

    internal init(session: URLSession = .shared) {
        self.session = session
    }

    /// The video id from any common YouTube URL form: watch?v=, youtu.be,
    /// /shorts/, /embed/, /live/. Nil for non-YouTube or non-video URLs.
    internal static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }
        let isYouTube = host == "youtube.com" || host == "youtu.be"
            || host.hasSuffix(".youtube.com")
        guard isYouTube else { return nil }

        if host == "youtu.be" {
            let id = url.pathComponents.first { $0 != "/" && !$0.isEmpty }
            return id?.isEmpty == false ? id : nil
        }
        if url.path == "/watch",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value,
           !id.isEmpty {
            return id
        }
        for prefix in ["/shorts/", "/embed/", "/live/"] where url.path.hasPrefix(prefix) {
            let rest = String(url.path.dropFirst(prefix.count))
            let id = rest.split(separator: "/").first.map(String.init) ?? ""
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// The watch URL for a video id (canonical form for oEmbed + opening).
    internal static func watchURL(for id: String) -> String {
        "https://www.youtube.com/watch?v=\(id)"
    }

    /// The embed-player URL (what the inline WKWebView loads on play).
    internal static func playerURL(for id: String, autoplay: Bool = true) -> String {
        "https://www.youtube.com/embed/\(id)?rel=0\(autoplay ? "&autoplay=1" : "")"
    }

    /// Fetch metadata for a video id; nil on any failure (cached).
    internal func embed(for videoID: String) async -> YouTubeEmbed? {
        if let cached = cache[videoID] { return cached }
        if let task = inFlight[videoID] { return await task.value }

        let task = Task<YouTubeEmbed?, Never> { [session] in
            var components = URLComponents(string: "https://www.youtube.com/oembed")
            components?.queryItems = [
                URLQueryItem(name: "url", value: Self.watchURL(for: videoID)),
                URLQueryItem(name: "format", value: "json"),
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
        inFlight[videoID] = task
        let result = await task.value
        inFlight[videoID] = nil
        cache[videoID] = result
        return result
    }

    /// Map the oEmbed JSON to a YouTubeEmbed.
    internal static func parse(data: Data) -> YouTubeEmbed? {
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            obj = parsed
        } catch {
            return nil
        }
        return YouTubeEmbed(
            title: obj["title"] as? String,
            channelName: obj["author_name"] as? String,
            channelURL: obj["author_url"] as? String,
            thumbnailURL: (obj["thumbnail_url"] as? String).flatMap { URL(string: $0) }
        )
    }
}
