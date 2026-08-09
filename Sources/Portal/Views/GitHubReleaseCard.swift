import SwiftUI

/// A GitHub release card, embedded directly in the feed: owner avatar, the
/// repo, a tag chip, release title, full release notes (markdown, expandable),
/// and the link underneath. Metadata (tag, author, date, FULL body) resolves
/// from the public GitHub API when the digest only stored a truncated summary.
internal struct GitHubReleaseCard: View {
    internal let article: FeedArticle
    /// Release-metadata fetcher owned by the feed surface (one cache per feed).
    internal let contentService: GitHubContentService

    @State private var embed: GitHubReleaseEmbed?
    @State private var isExpanded = false
    @State private var browserLink: InAppBrowserLink?

    private var ownerRepo: (owner: String, repo: String)? {
        GitHubContentService.ownerRepo(for: article.url)
    }

    private var repoDisplayName: String {
        ownerRepo.map { "\($0.owner)/\($0.repo)" } ?? article.title
    }

    private var releaseTitle: String? {
        let name = embed?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let articleTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !name.isEmpty ? name : articleTitle
        // Don't repeat the repo name or the tag as the title.
        guard !title.isEmpty, title != repoDisplayName, title != embed?.tagName else { return nil }
        return title
    }

    private var tagName: String? {
        embed?.tagName
    }

    /// Full release notes: the API's untruncated body, else the digest's
    /// (capped) summary. Nothing when both are empty.
    private var releaseBody: String? {
        if let body = embed?.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        let summary = article.displaySummary
        return summary.isEmpty ? nil : summary
    }

    private var releaseURL: URL? {
        (embed?.htmlURL).flatMap { URL(string: $0) } ?? URL(string: article.url)
    }

    /// Avatar: the release author's GitHub avatar, else the repo owner's
    /// (github.com/{owner}.png is a free, unauthenticated mirror).
    private var avatarURL: URL? {
        embed?.authorAvatarURL ?? ownerRepo.flatMap { URL(string: "https://github.com/\($0.owner).png") }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            if let releaseTitle {
                Text(releaseTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            if let releaseBody {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownContentView(text: releaseBody)
                        .lineLimit(isExpanded ? nil : 8)
                        .clipped()
                }
                .padding(.top, 6)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Read full notes")
                            .font(.caption.weight(.medium))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            if let releaseURL {
                linkRow(releaseURL)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { openRelease() }
        .sheet(item: $browserLink) { link in
            InAppBrowserView(link: link)
        }
        .task(id: article.url) { await fetchEmbedIfNeeded() }
    }

    // MARK: - Header (avatar / repo / tag / time)

    private var headerRow: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(repoDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let login = embed?.authorLogin {
                        Text(login)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    Text(article.relativeTime)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            if let tagName {
                Text(tagName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accent.opacity(0.12))
            if let url = avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "chevron.left.slash.chevron.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                    }
                }
            } else {
                Image(systemName: "chevron.left.slash.chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Link row

    private func linkRow(_ url: URL) -> some View {
        Button(action: openRelease) {
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

    private func openRelease() {
        guard let releaseURL else { return }
        browserLink = InAppBrowserLink(urlString: releaseURL.absoluteString, title: repoDisplayName)
    }

    private func fetchEmbedIfNeeded() async {
        guard embed == nil else { return }
        embed = await contentService.release(for: article.url)
    }
}

// MARK: - Preview

#if DEBUG
internal struct GitHubReleaseCard_Previews: PreviewProvider {
    internal static var previews: some View {
        GitHubReleaseCard(
            article: FeedArticle(
                id: "g1", title: "llama.cpp b10213",
                url: "https://github.com/ggml-org/llama.cpp/releases/tag/b10213",
                summary: "Support rotated kv cache quant (#26180)",
                source: "github", tags: [], imageUrl: "",
                ts: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5400))
            ),
            contentService: GitHubContentService()
        )
        .padding()
        .background(Theme.background)
    }
}
#endif
