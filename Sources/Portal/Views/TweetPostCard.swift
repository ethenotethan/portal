import SwiftUI

/// An X-style tweet card, embedded directly in the feed for `twitter` items.
/// Read-only replica of X's post layout — avatar/name/handle/timestamp header,
/// tweet body, media, and the reply / repost / like / views action bar — with
/// an inline, expandable comments section (each reply clicks through to its
/// own post). No write actions anywhere: the affordances keep X's design
/// intent so real engagement data drops in when the backend enriches it.
/// Tapping the card opens the tweet in the in-app browser.
internal struct TweetPostCard: View {
    internal let article: FeedArticle
    /// Embed fetcher owned by the feed surface (one cache per feed; injected
    /// so tests can stub the network).
    internal let contentService: TweetContentService

    @State private var commentsExpanded = false
    @State private var browserLink: InAppBrowserLink?
    @State private var embed: TweetEmbed?
    @State private var isFetchingEmbed = false

    private var tweetURL: URL? {
        guard !article.url.isEmpty else { return nil }
        return URL(string: article.url)
    }

    /// Header display name: backend author_name → syndication author → handle.
    private var displayName: String? {
        article.authorName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? article.authorName
            : embed?.authorName ?? article.tweetHandle
    }

    /// Header handle: backend author_handle → syndication author → title/URL.
    private var displayHandle: String? {
        article.tweetHandle ?? embed?.authorHandle
    }

    /// Avatar: syndication's profile image (best), then the backend's, then
    /// the unavatar mirror for the handle.
    private var avatarURL: URL? {
        embed?.avatarURL ?? article.tweetAvatarURL
    }

    /// The tweet's text: the fetched syndication contents when the digest
    /// only stored a bare URL, else the digest's own body.
    private var tweetText: String? {
        if let text = embed?.text, !text.isEmpty { return text }
        return article.cardBody.isEmpty ? nil : article.cardBody
    }

    /// Media: the digest's hero, else media resolved from the syndication.
    private var mediaURLs: [URL] {
        if let hero = article.heroImageURL { return [hero] }
        return embed?.mediaURLs ?? []
    }

    /// Replies action-bar count: backend metric → syndication count → inlined
    /// replies — never a fake "0".
    private var replyCount: Int? {
        article.metrics?.replies ?? embed?.replyCount
            ?? (article.replies.isEmpty ? nil : article.replies.count)
    }

    /// Likes action-bar count: backend metric → syndication favorite_count.
    private var likeCount: Int? {
        article.metrics?.likes ?? embed?.likeCount
    }

    /// The thread above this tweet, oldest first (flattened parent chain).
    private var threadParents: [TweetEmbed] {
        embed?.thread ?? []
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thread context above the linked tweet (parent chain).
            ForEach(threadParents, id: \.url) { parent in
                threadRow(parent)
            }

            headerRow

            if let text = tweetText {
                LinkifiedText(text: text)
                    .padding(.top, 4)
            } else if isFetchingEmbed {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("Fetching tweet…")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 6)
            }

            ForEach(mediaURLs, id: \.absoluteString) { url in
                FeedHeroImage(url: url)
                    .padding(.top, 10)
            }

            // The tweet's link, always pinned under the contents.
            if let tweetURL {
                linkRow(tweetURL)
                    .padding(.top, tweetText != nil ? 8 : 6)
            }

            actionBar
                .padding(.top, 8)

            if !article.replies.isEmpty {
                commentsSection
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { openArticle() }
        .sheet(item: $browserLink) { link in
            InAppBrowserView(link: link)
        }
        .task(id: article.url) { await fetchEmbedIfNeeded() }
    }

    // MARK: - Header (avatar / name / handle / time)

    private var headerRow: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName ?? "Unknown")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let handle = displayHandle {
                        Text("@\(handle)")
                            .foregroundStyle(Theme.secondary)
                    }
                    Text("· \(article.relativeTime)")
                        .foregroundStyle(Theme.secondary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // X wordmark stand-in; the whole card clicks through to the post.
            Image(systemName: "bird")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary.opacity(0.6))
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.15))
            if let url = avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var monogram: some View {
        Text(String((displayName ?? "?").prefix(1)).uppercased())
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Theme.accent)
    }

    // MARK: - Tweet link row

    /// The tweet's URL, pinned under the contents — the click-through.
    private func linkRow(_ url: URL) -> some View {
        Button(action: openArticle) {
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

    // MARK: - oEmbed fetch

    /// The digest often stores only a bare tweet URL — resolve the actual
    /// tweet contents (and author) from X's public oEmbed endpoint. Silent on
    /// failure: the card keeps whatever the digest gave it.
    private func fetchEmbedIfNeeded() async {
        guard embed == nil, !isFetchingEmbed,
              TweetContentService.isTweetStatusURL(article.url) else { return }
        isFetchingEmbed = true
        embed = await contentService.embed(for: article.url)
        isFetchingEmbed = false
    }

    // MARK: - Action bar (read-only)

    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton(
                icon: "bubble",
                count: replyCount,
                tint: Theme.secondary,
                help: article.replies.isEmpty ? "Replies" : "Show replies"
            ) {
                guard !article.replies.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.22)) { commentsExpanded.toggle() }
            }
            Spacer()
            actionButton(
                icon: "arrow.2.squarepath",
                count: article.metrics?.reposts,
                tint: Theme.secondary,
                help: "Reposts"
            ) { openArticle() }
            Spacer()
            actionButton(
                icon: "heart",
                count: likeCount,
                tint: Theme.secondary,
                help: "Likes"
            ) { openArticle() }
            Spacer()
            actionButton(
                icon: "chart.bar",
                count: article.metrics?.views,
                tint: Theme.secondary,
                help: "Views"
            ) { openArticle() }
            Spacer()
            Button(action: openArticle) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Open on X")
        }
    }

    private func actionButton(
        icon: String, count: Int?, tint: Color, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                if let count {
                    Text(TweetMetrics.compact(count))
                        .font(.caption)
                }
            }
            .foregroundStyle(tint)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Comments (expandable, read-only)

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { commentsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: commentsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(article.replies.count) repl\(article.replies.count == 1 ? "y" : "ies")")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Theme.secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if commentsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(article.replies) { reply in
                        replyRow(reply)
                        if reply.id != article.replies.last?.id {
                            Divider().overlay(Theme.border.opacity(0.5))
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 4)
    }

    private func replyRow(_ reply: FeedReply) -> some View {
        Button {
            browserLink = InAppBrowserLink(urlString: reply.url, title: reply.authorName)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text(String(reply.authorName.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(reply.authorName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if !reply.authorHandle.isEmpty {
                            Text("@\(reply.authorHandle)")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(reply.text)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openArticle() {
        guard let tweetURL else { return }
        browserLink = InAppBrowserLink(urlString: tweetURL.absoluteString, title: displayName)
    }

    // MARK: - Thread rows (parent chain)

    /// One parent tweet in the thread above the linked tweet: compact, with
    /// X's vertical connector down to the next tweet in the chain. Click
    /// opens the parent itself.
    private func threadRow(_ parent: TweetEmbed) -> some View {
        Button {
            if !parent.url.isEmpty {
                browserLink = InAppBrowserLink(urlString: parent.url, title: parent.authorName)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text(String((parent.authorName ?? parent.authorHandle ?? "?").prefix(1)).uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        )
                    Rectangle()
                        .fill(Theme.secondary.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(parent.authorName ?? "Unknown")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if let handle = parent.authorHandle {
                            Text("@\(handle)")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                    }
                    LinkifiedText(text: parent.text, font: .caption, color: Theme.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Linkified plain text

/// Plain tweet text with tappable URLs — NO markdown parsing (a tweet's `#`,
/// `_`, and `*` are literal characters, not headings/emphasis). Matches X's
/// presentation: body text in the base color, links tinted and clickable.
internal struct LinkifiedText: View {
    internal let text: String
    internal var font: Font = .body
    internal var color: Color = Theme.primary

    internal var body: some View {
        Text(attributed)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        while let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression, range: cursor..<text.endIndex) {
            if cursor < range.lowerBound {
                var plain = AttributedString(String(text[cursor..<range.lowerBound]))
                plain.foregroundColor = color
                result.append(plain)
            }
            let raw = String(text[range])
            var link = AttributedString(raw)
            if let url = URL(string: raw) {
                link.link = url
                link.foregroundColor = Theme.accent
            } else {
                link.foregroundColor = color
            }
            result.append(link)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            var tail = AttributedString(String(text[cursor...]))
            tail.foregroundColor = color
            result.append(tail)
        }
        return result
    }
}

// MARK: - Preview

#if DEBUG
internal struct TweetPostCard_Previews: PreviewProvider {
    internal static var previews: some View {
        TweetPostCard(
            article: FeedArticle(
                id: "t1", title: "@janedoe",
                url: "https://x.com/janedoe/status/123",
                summary: "Shipping the new graph explorer today — pan, zoom, and click-through neighbors, all native. No web views were harmed.",
                source: "twitter", tags: [], imageUrl: "",
                ts: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
                authorName: "Jane Doe", authorHandle: "janedoe",
                metrics: TweetMetrics(replies: 12, reposts: 48, likes: 1204, views: 22_000),
                replies: [
                    FeedReply(id: "r1", authorName: "Dev One", authorHandle: "devone",
                              text: "This is exactly what the feed needed.", url: "https://x.com/devone/status/124"),
                    FeedReply(id: "r2", authorName: "Dev Two", authorHandle: "devtwo",
                              text: "Does it handle 1k nodes?", url: "https://x.com/devtwo/status/125"),
                ]
            ),
            contentService: TweetContentService()
        )
        .padding()
        .background(Theme.background)
    }
}
#endif
