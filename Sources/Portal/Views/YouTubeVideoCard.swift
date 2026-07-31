import SwiftUI

/// A YouTube video card, embedded directly in the feed: thumbnail with a play
/// badge, channel + title, the link underneath — and TAP-TO-PLAY INLINE: the
/// thumbnail swaps to YouTube's embed player (WKWebView, no login) right in
/// the card. Metadata (title/channel/hq thumbnail) resolves from YouTube's
/// public oEmbed endpoint when the digest only stored a bare URL.
internal struct YouTubeVideoCard: View {
    internal let article: FeedArticle
    /// oEmbed fetcher owned by the feed surface (one cache per feed).
    internal let contentService: YouTubeContentService

    @State private var embed: YouTubeEmbed?
    @State private var isPlaying = false
    @State private var browserLink: InAppBrowserLink?

    private var videoID: String? {
        YouTubeContentService.videoID(from: article.url)
    }

    private var watchURL: URL? {
        videoID.flatMap { URL(string: YouTubeContentService.watchURL(for: $0)) }
            ?? URL(string: article.url)
    }

    private var title: String {
        if let t = embed?.title, !t.isEmpty { return t }
        let t = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "YouTube video" : t
    }

    private var channelName: String? {
        embed?.channelName
    }

    /// hq thumbnail: the digest's own image, else oEmbed, else the canonical
    /// i.ytimg.com mirror for the video id.
    private var thumbnailURL: URL? {
        article.heroImageURL
            ?? embed?.thumbnailURL
            ?? videoID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            playerArea

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                if let channelName {
                    Text(channelName)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                Text("YouTube")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Text("· \(article.relativeTime)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.top, 6)

            if let watchURL {
                linkRow(watchURL)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { openInBrowser() }
        .sheet(item: $browserLink) { link in
            InAppBrowserView(link: link)
        }
        .task(id: article.url) { await fetchEmbedIfNeeded() }
    }

    // MARK: - Player area (thumbnail → inline player)

    @ViewBuilder
    private var playerArea: some View {
        if isPlaying, let videoID {
            // Inline YouTube embed (WKWebView) — the card becomes the player.
            InlineHTMLView(html: Self.playerHTML(videoID: videoID))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )
        } else {
            Button { isPlaying = true } label: {
                ZStack {
                    if let thumbnailURL {
                        AsyncImage(url: thumbnailURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(16.0 / 9.0, contentMode: .fill)
                            default:
                                thumbnailPlaceholder
                            }
                        }
                    } else {
                        thumbnailPlaceholder
                    }

                    // Play badge
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red)
                            .frame(width: 52, height: 36)
                        Image(systemName: "play.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help("Play inline")
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.10))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                Image(systemName: "play.rectangle")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.secondary.opacity(0.5))
            )
    }

    /// Minimal document hosting YouTube's embed iframe — JS on, isolated in
    /// the same ephemeral WKWebView the app's other inline pages use.
    private static func playerHTML(videoID: String) -> String {
        let src = YouTubeContentService.playerURL(for: videoID)
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}\
        iframe{width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(src)"
          allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture"
          allowfullscreen></iframe>
        </body></html>
        """
    }

    // MARK: - Link row

    private func linkRow(_ url: URL) -> some View {
        Button(action: openInBrowser) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.caption2)
                Text(url.absoluteString)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func openInBrowser() {
        guard let watchURL else { return }
        browserLink = InAppBrowserLink(urlString: watchURL.absoluteString, title: title)
    }

    private func fetchEmbedIfNeeded() async {
        guard embed == nil, let videoID else { return }
        embed = await contentService.embed(for: videoID)
    }
}

// MARK: - Preview

#if DEBUG
internal struct YouTubeVideoCard_Previews: PreviewProvider {
    internal static var previews: some View {
        YouTubeVideoCard(
            article: FeedArticle(
                id: "v1", title: "",
                url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                summary: "", source: "youtube", tags: [], imageUrl: "",
                ts: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
            ),
            contentService: YouTubeContentService()
        )
        .padding()
        .background(Theme.background)
    }
}
#endif
