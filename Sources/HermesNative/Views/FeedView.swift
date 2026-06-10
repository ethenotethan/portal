import SwiftUI

/// Instagram/Twitter-style curated news feed from the digest pipeline.
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

            if let error = vm.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text(error).font(.caption)
                    Spacer()
                    Button("Retry") { Task { await vm.loadFeed(client: gatewayClientWrapper.client) } }.font(.caption)
                }
                .padding(.horizontal).padding(.vertical, 6)
                .background(Color.yellow.opacity(0.1))
            }

            if vm.articles.isEmpty && !vm.isLoading {
                emptyState
            } else {
                articleList
            }
        }
        .navigationTitle("Feed")
        .task { if vm.articles.isEmpty { await vm.loadFeed(client: gatewayClientWrapper.client) } }
    }

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.articles) { article in
                    FeedCard(article: article)
                        .padding(.horizontal).padding(.vertical, 10)
                        .onAppear {
                            if article.id == vm.articles.last?.id {
                                Task { await vm.loadMore(client: gatewayClientWrapper.client) }
                            }
                        }
                    Divider().padding(.leading, 16)
                }
            }
            .padding(.top, 8)
            if vm.isLoadingMore { ProgressView().padding() }
        }
        .refreshable { await vm.refresh(client: gatewayClientWrapper.client) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if vm.isLoading { ProgressView().scaleEffect(1.2) }
            else {
                Image(systemName: "newspaper").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.5))
                Text("No articles yet").font(.headline).foregroundColor(.secondary)
                Text("Articles from your research digests will appear here as the pipeline runs.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Source Filter Bar

struct SourceFilterBar: View {
    let sources: [String: Int]
    let selected: String?
    let onSelect: (String?) -> Void

    private var orderedSources: [(String, Int)] {
        let order = ["arxiv", "github", "blog", "twitter"]
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
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Color(.windowBackgroundColor))
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "arxiv": return "Papers"
        case "github": return "Releases"
        case "blog": return "Blogs"
        case "twitter": return "X"
        default: return s.capitalized
        }
    }
    private func sourceIcon(_ s: String) -> String {
        switch s {
        case "arxiv": return "doc.text.magnifyingglass"
        case "github": return "chevron.left.slash.chevron.right"
        case "blog": return "text.bubble"
        case "twitter": return "bird"
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

// MARK: - Feed Card

struct FeedCard: View {
    let article: FeedArticle
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: article.sourceIcon).font(.caption2)
                Text(article.sourceLabel).font(.caption).fontWeight(.medium).foregroundColor(sourceColor(article.source))
                Spacer()
                Text(article.relativeTime).font(.caption2).foregroundColor(.secondary)
            }
            Text(article.title).font(.headline).lineLimit(isExpanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
            if !article.summary.isEmpty {
                Text(article.summary).font(.subheadline).foregroundColor(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !article.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(article.tags.prefix(isExpanded ? article.tags.count : 5), id: \.self) { tag in
                            Text(tag).font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1)).cornerRadius(6)
                        }
                    }
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !article.url.isEmpty {
                        Button {
                            #if os(macOS)
                            NSWorkspace.shared.open(URL(string: article.url)!)
                            #else
                            UIApplication.shared.open(URL(string: article.url)!)
                            #endif
                        } label: {
                            Label(article.url, systemImage: "safari")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.bordered)
                        .tint(sourceColor(article.source))
                    }
                    if !article.summary.isEmpty {
                        Text(article.summary)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }
    private func sourceColor(_ s: String) -> Color {
        switch s {
        case "arxiv": return .blue
        case "github": return .purple
        case "blog": return .orange
        case "twitter": return .cyan
        default: return .gray
        }
    }
}
