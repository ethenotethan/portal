import SwiftUI
import AVKit

// MARK: - Feed View

/// Social-media-style curated feed from the digest pipeline.
struct FeedView: View {
    @StateObject private var vm = FeedViewModel()
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper

    var body: some View {
        VStack(spacing: 0) {
            SourceFilterBar(
                sources: vm.sourceCounts,
                selected: vm.selectedSource,
                onSelect: { vm.selectSource($0, client: gatewayClientWrapper.client) }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let error = vm.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text(error).font(.caption)
                    Spacer()
                    Button("Retry") { Task { await vm.loadFeed(client: gatewayClientWrapper.client) } }.font(.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.yellow.opacity(0.1))
            }

            if vm.articles.isEmpty && !vm.isLoading {
                emptyState
            } else if vm.isLoading && vm.articles.isEmpty {
                loadingSkeleton
            } else {
                articleFeed
            }
        }
        .navigationTitle("Feed")
        .background(Theme.background)
        .task { if vm.articles.isEmpty { await vm.loadFeed(client: gatewayClientWrapper.client) } }
    }

    // MARK: - Article Feed

    private var articleFeed: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(vm.articles) { article in
                    if article.hasVideo {
                        VideoFeedCard(article: article)
                            .padding(.horizontal, 12)
                    } else {
                        FeedCard(article: article)
                            .padding(.horizontal, 12)
                            .onAppear {
                                if article.id == vm.articles.last?.id {
                                    Task { await vm.loadMore(client: gatewayClientWrapper.client) }
                                }
                            }
                    }
                }

                if vm.isLoadingMore {
                    HStack { Spacer(); ProgressView().padding(); Spacer() }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await vm.refresh(client: gatewayClientWrapper.client) }
    }

    // MARK: - Empty / Loading States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "newspaper").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.4))
            Text("No articles yet").font(.headline).foregroundColor(.secondary)
            Text("Articles from your research digests will appear here as the pipeline runs.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private var loadingSkeleton: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonCard().padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Skeleton Card

struct SkeletonCard: View {
    @State private var shimmer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)).frame(width: 28, height: 28)
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 80, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 50, height: 10)
            }
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 14)
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 200, height: 14)
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 12)
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 120, height: 12)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
        )
        .opacity(shimmer ? 0.4 : 0.8)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - Source Filter Bar

struct SourceFilterBar: View {
    let sources: [String: Int]
    let selected: String?
    let onSelect: (String?) -> Void

    private var orderedSources: [(String, Int)] {
        let order = ["arxiv", "github", "blog", "twitter", "digest_video"]
        var result: [(String, Int)] = []
        for key in order { if let count = sources[key], count > 0 { result.append((key, count)) } }
        for (key, count) in sources.sorted(by: { $0.value > $1.value }) where !order.contains(key) {
            result.append((key, count))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                SourcePill(label: "All", count: sources.values.reduce(0, +),
                    isSelected: selected == nil, icon: "square.grid.2x2")
                    .onTapGesture { onSelect(nil) }
                ForEach(orderedSources, id: \.0) { source, count in
                    SourcePill(label: sourceLabel(source), count: count,
                        isSelected: selected == source, icon: sourceIcon(source))
                        .onTapGesture { onSelect(source) }
                }
            }
        }
        #if os(macOS)
        .background(Theme.surface)
        #else
        .background(Color(.systemBackground))
        #endif
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "arxiv": return "Papers"
        case "github": return "Releases"
        case "blog": return "Blogs"
        case "twitter": return "X"
        case "digest_video": return "Video"
        default: return s.capitalized
        }
    }
    private func sourceIcon(_ s: String) -> String {
        switch s {
        case "arxiv": return "doc.text.magnifyingglass"
        case "github": return "chevron.left.slash.chevron.right"
        case "blog": return "text.bubble"
        case "twitter": return "bird"
        case "digest_video": return "play.rectangle"
        default: return "newspaper"
        }
    }
}

struct SourcePill: View {
    let label: String; let count: Int; let isSelected: Bool; let icon: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption)
            Text("\(count)").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12)))
        .foregroundColor(isSelected ? .white : .primary)
    }
}

// MARK: - Hero Image

/// Async-loaded article/release image with rounded social-card styling.
/// Collapses to nothing on failure so broken URLs never leave a gap.
struct FeedHeroImage: View {
    let url: URL
    @State private var failed = false

    var body: some View {
        if !failed {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                        )
                case .empty:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(height: 160)
                        .overlay(ProgressView().controlSize(.small))
                case .failure:
                    Color.clear.frame(height: 0)
                        .onAppear { failed = true }
                @unknown default:
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
}

// MARK: - Feed Card

struct FeedCard: View {
    let article: FeedArticle
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(sourceColor(article.source).opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: article.sourceIcon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(sourceColor(article.source))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(article.twitterAuthor ?? article.sourceLabel)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(article.twitterAuthor != nil ? "\(article.sourceLabel) · \(article.relativeTime)" : article.relativeTime)
                        .font(.caption2).foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Circle().fill(Color.secondary.opacity(0.08)))
            }

            // Tweets carry their content in the body, not a headline, so skip
            // the bold title (it's just the handle, already shown in the header)
            // and lead with the tweet text. Other sources keep the headline.
            if !article.isTwitter {
                MarkdownText(text: article.title)
                    .font(.body).fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(isExpanded ? nil : 2)
                    .padding(.top, 10)
            }

            if let heroURL = article.heroImageURL {
                FeedHeroImage(url: heroURL)
                    .padding(.top, 10)
            }

            if !article.cardBody.isEmpty {
                if isExpanded {
                    MarkdownContentView(text: article.isTwitter ? article.cardBody : article.displaySummary)
                        .padding(.top, 8)
                } else {
                    MarkdownText(text: article.cardBody)
                        .font(article.isTwitter ? .body : .subheadline)
                        .foregroundColor(article.isTwitter ? .primary : .secondary)
                        .lineLimit(article.isTwitter ? 8 : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, article.isTwitter ? 10 : 6)
                }
            }

            if !article.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(article.tags.prefix(isExpanded ? article.tags.count : 4), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(sourceColor(article.source).opacity(0.08))
                                .foregroundColor(sourceColor(article.source))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.top, 8)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    if let validURL = URL(string: article.url), !article.url.isEmpty {
                        Button {
                            #if os(macOS)
                            NSWorkspace.shared.open(validURL)
                            #else
                            UIApplication.shared.open(validURL)
                            #endif
                        } label: {
                            HStack {
                                Image(systemName: "safari")
                                Text(article.url).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: "arrow.up.forward")
                            }
                            .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(sourceColor(article.source).opacity(0.1))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sourceColor(article.source).opacity(0.2), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 24) {
                if let validURL = URL(string: article.url), !article.url.isEmpty {
                    Button {
                        #if os(macOS)
                        NSWorkspace.shared.open(validURL)
                        #else
                        UIApplication.shared.open(validURL)
                        #endif
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "safari").font(.caption2)
                            Text("Open").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(sourceColor(article.source))
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "text.justify.leading").font(.caption2)
                        Text(isExpanded ? "Less" : "More").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.top, article.displaySummary.isEmpty && article.tags.isEmpty ? 6 : 10)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() } }
    }

    private func sourceColor(_ s: String) -> Color {
        switch s {
        case "arxiv": return .blue
        case "github": return .purple
        case "blog": return .orange
        case "twitter": return .cyan
        case "digest_video": return .red
        default: return .gray
        }
    }
}

// MARK: - Video Feed Card

/// Feed card variant with inline video player via AVKit.
struct VideoFeedCard: View {
    let article: FeedArticle
    @State private var isExpanded = false
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(sourceColor(article.source).opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: article.sourceIcon).font(.system(size: 14, weight: .medium)).foregroundColor(sourceColor(article.source))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(article.sourceLabel).font(.subheadline).fontWeight(.semibold)
                    Text(article.relativeTime).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundColor(.secondary).padding(6)
                    .background(Circle().fill(Color.secondary.opacity(0.08)))
            }
            MarkdownText(text: article.title).font(.body).fontWeight(.semibold).lineLimit(isExpanded ? nil : 2).padding(.top, 10)
            if !article.displaySummary.isEmpty {
                MarkdownText(text: article.previewSummary).font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            if isExpanded {
                VideoPlayerView(videoURL: article.videoUrl, thumbnailURL: article.thumbnailUrl, isPlaying: $isPlaying)
                    .frame(height: 220).cornerRadius(12).padding(.top, 10)
            } else {
                ZStack {
                    if let url = URL(string: article.thumbnailUrl), !article.thumbnailUrl.isEmpty {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(16/9, contentMode: .fill)
                            } else { thumbnailPlaceholder }
                        }
                    } else { thumbnailPlaceholder }
                }
                .frame(height: 180).clipped().cornerRadius(12)
                .overlay(ZStack {
                    Circle().fill(.ultraThinMaterial).frame(width: 52, height: 52)
                    Image(systemName: "play.fill").font(.title2).foregroundColor(.white).offset(x: 1)
                }).padding(.top, 10)
            }
            if !article.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(article.tags.prefix(5), id: \.self) { tag in
                            Text(tag).font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(sourceColor(article.source).opacity(0.08)).foregroundColor(sourceColor(article.source)).cornerRadius(6)
                        }
                    }
                }.padding(.top, 8)
            }
            HStack(spacing: 24) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { isExpanded.toggle(); isPlaying = isExpanded }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.caption2)
                        Text(isExpanded ? "Collapse" : "Watch").font(.caption2)
                    }
                }.buttonStyle(.plain).foregroundColor(sourceColor(article.source))
                Spacer()
            }.padding(.top, 10)
        }
        .padding(16).background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { isExpanded.toggle(); isPlaying = isExpanded } }
    }
    private var thumbnailPlaceholder: some View {
        ZStack {
            Rectangle().fill(sourceColor(article.source).opacity(0.12))
            Image(systemName: "play.rectangle").font(.largeTitle).foregroundColor(sourceColor(article.source).opacity(0.4))
        }
    }
    private func sourceColor(_ s: String) -> Color {
        switch s {
        case "arxiv": return .blue
        case "github": return .purple
        case "blog": return .orange
        case "twitter": return .cyan
        case "digest_video": return .red
        default: return .gray
        }
    }
}

// MARK: - Video Player (Inline)

/// Inline video player — uses native AVPlayerView (macOS) or VideoPlayer (iOS).
struct VideoPlayerView: View {
    let videoURL: String; let thumbnailURL: String
    @Binding var isPlaying: Bool
    @State private var player: AVPlayer?

    var body: some View {
        #if os(macOS)
        NativeVideoPlayer(player: player, videoURL: videoURL)
            .onAppear { if let url = URL(string: videoURL) { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause(); player = nil }
        #else
        VideoPlayer(player: player)
            .onAppear { if let url = URL(string: videoURL) { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause(); player = nil }
        #endif
    }
}

#if os(macOS)
import AppKit
import WebKit

/// WKWebView video player for macOS — HTML5 <video> is the most reliable playback method.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?
    let videoURL: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        // Navigate directly to video URL — WKWebView plays video natively
        if let url = URL(string: videoURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.stopLoading()
    }
}
#endif
