     1|import SwiftUI
     2|
     3|// MARK: - Feed View
     4|
     5|/// Social-media-style curated feed from the digest pipeline.
     6|struct FeedView: View {
     7|    @StateObject private var vm = FeedViewModel()
     8|    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
     9|
    10|    var body: some View {
    11|        VStack(spacing: 0) {
    12|            SourceFilterBar(
    13|                sources: vm.sourceCounts,
    14|                selected: vm.selectedSource,
    15|                onSelect: { vm.selectSource($0, client: gatewayClientWrapper.client) }
    16|            )
    17|            .padding(.horizontal, 12)
    18|            .padding(.vertical, 6)
    19|
    20|            if let error = vm.error {
    21|                HStack {
    22|                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
    23|                    Text(error).font(.caption)
    24|                    Spacer()
    25|                    Button("Retry") { Task { await vm.loadFeed(client: gatewayClientWrapper.client) } }.font(.caption)
    26|                }
    27|                .padding(.horizontal, 16).padding(.vertical, 6)
    28|                .background(Color.yellow.opacity(0.1))
    29|            }
    30|
    31|            if vm.articles.isEmpty && !vm.isLoading {
    32|                emptyState
    33|            } else if vm.isLoading && vm.articles.isEmpty {
    34|                loadingSkeleton
    35|            } else {
    36|                articleFeed
    37|            }
    38|        }
    39|        .navigationTitle("Feed")
    40|        .background(Theme.background)
    41|        .task { if vm.articles.isEmpty { await vm.loadFeed(client: gatewayClientWrapper.client) } }
    42|    }
    43|
    44|    // MARK: - Article Feed
    45|
    46|    private var articleFeed: some View {
    47|        ScrollView {
    48|            LazyVStack(spacing: 12) {
    49|                ForEach(vm.articles) { article in
    50|                    FeedCard(article: article)
    51|                        .padding(.horizontal, 12)
    52|                        .onAppear {
    53|                            if article.id == vm.articles.last?.id {
    54|                                Task { await vm.loadMore(client: gatewayClientWrapper.client) }
    55|                            }
    56|                        }
    57|                }
    58|
    59|                if vm.isLoadingMore {
    60|                    HStack { Spacer(); ProgressView().padding(); Spacer() }
    61|                }
    62|            }
    63|            .padding(.vertical, 12)
    64|        }
    65|        .refreshable { await vm.refresh(client: gatewayClientWrapper.client) }
    66|    }
    67|
    68|    // MARK: - Empty / Loading States
    69|
    70|    private var emptyState: some View {
    71|        VStack(spacing: 16) {
    72|            Spacer()
    73|            Image(systemName: "newspaper").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.4))
    74|            Text("No articles yet").font(.headline).foregroundColor(.secondary)
    75|            Text("Articles from your research digests will appear here as the pipeline runs.")
    76|                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
    77|            Spacer()
    78|        }
    79|    }
    80|
    81|    private var loadingSkeleton: some View {
    82|        ScrollView {
    83|            LazyVStack(spacing: 12) {
    84|                ForEach(0..<6, id: \.self) { _ in
    85|                    SkeletonCard().padding(.horizontal, 12)
    86|                }
    87|            }
    88|            .padding(.vertical, 12)
    89|        }
    90|    }
    91|}
    92|
    93|// MARK: - Skeleton Card
    94|
    95|struct SkeletonCard: View {
    96|    @State private var shimmer = false
    97|    var body: some View {
    98|        VStack(alignment: .leading, spacing: 10) {
    99|            HStack(spacing: 8) {
   100|                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)).frame(width: 28, height: 28)
   101|                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 80, height: 12)
   102|                Spacer()
   103|                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 50, height: 10)
   104|            }
   105|            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 14)
   106|            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 200, height: 14)
   107|            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 12)
   108|            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 120, height: 12)
   109|        }
   110|        .padding(16)
   111|        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
   112|        .overlay(
   113|            RoundedRectangle(cornerRadius: 16)
   114|                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
   115|        )
   116|        .opacity(shimmer ? 0.4 : 0.8)
   117|        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: shimmer)
   118|        .onAppear { shimmer = true }
   119|    }
   120|}
   121|
   122|// MARK: - Source Filter Bar
   123|
   124|struct SourceFilterBar: View {
   125|    let sources: [String: Int]
   126|    let selected: String?
   127|    let onSelect: (String?) -> Void
   128|
   129|    private var orderedSources: [(String, Int)] {
   130|        let order = ["arxiv", "github", "blog", "twitter"]
   131|        var result: [(String, Int)] = []
   132|        for key in order { if let count = sources[key], count > 0 { result.append((key, count)) } }
   133|        for (key, count) in sources.sorted(by: { $0.value > $1.value }) where !order.contains(key) {
   134|            result.append((key, count))
   135|        }
   136|        return result
   137|    }
   138|
   139|    var body: some View {
   140|        ScrollView(.horizontal, showsIndicators: false) {
   141|            HStack(spacing: 8) {
   142|                SourcePill(label: "All", count: sources.values.reduce(0, +),
   143|                    isSelected: selected == nil, icon: "square.grid.2x2")
   144|                    .onTapGesture { onSelect(nil) }
   145|                ForEach(orderedSources, id: \.0) { source, count in
   146|                    SourcePill(label: sourceLabel(source), count: count,
   147|                        isSelected: selected == source, icon: sourceIcon(source))
   148|                        .onTapGesture { onSelect(source) }
   149|                }
   150|            }
   151|        }
   152|        #if os(macOS)
   153|        .background(Theme.surface)
   154|        #else
   155|        .background(Color(.systemBackground))
   156|        #endif
   157|    }
   158|
   159|    private func sourceLabel(_ s: String) -> String {
   160|        switch s {
   161|        case "arxiv": return "Papers"
   162|        case "github": return "Releases"
   163|        case "blog": return "Blogs"
   164|        case "twitter": return "X"
   165|        default: return s.capitalized
   166|        }
   167|    }
   168|    private func sourceIcon(_ s: String) -> String {
   169|        switch s {
   170|        case "arxiv": return "doc.text.magnifyingglass"
   171|        case "github": return "chevron.left.slash.chevron.right"
   172|        case "blog": return "text.bubble"
   173|        case "twitter": return "bird"
   174|        default: return "newspaper"
   175|        }
   176|    }
   177|}
   178|
   179|struct SourcePill: View {
   180|    let label: String; let count: Int; let isSelected: Bool; let icon: String
   181|    var body: some View {
   182|        HStack(spacing: 4) {
   183|            Image(systemName: icon).font(.caption2)
   184|            Text(label).font(.caption)
   185|            Text("\(count)").font(.caption2).foregroundColor(.secondary)
   186|        }
   187|        .padding(.horizontal, 10).padding(.vertical, 6)
   188|        .background(RoundedRectangle(cornerRadius: 12)
   189|            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12)))
   190|        .foregroundColor(isSelected ? .white : .primary)
   191|    }
   192|}
   193|
   194|// MARK: - Feed Card
   195|
   196|struct FeedCard: View {
   197|    let article: FeedArticle
   198|    @State private var isExpanded = false
   199|
   200|    var body: some View {
   201|        VStack(alignment: .leading, spacing: 0) {
   202|            // Header row — source avatar + name + time
   203|            HStack(spacing: 10) {
   204|                // Source avatar circle
   205|                ZStack {
   206|                    Circle()
   207|                        .fill(sourceColor(article.source).opacity(0.15))
   208|                        .frame(width: 36, height: 36)
   209|                    Image(systemName: article.sourceIcon)
   210|                        .font(.system(size: 14, weight: .medium))
   211|                        .foregroundColor(sourceColor(article.source))
   212|                }
   213|
   214|                VStack(alignment: .leading, spacing: 1) {
   215|                    Text(article.sourceLabel)
   216|                        .font(.subheadline).fontWeight(.semibold)
   217|                        .foregroundColor(.primary)
   218|                    Text(article.relativeTime)
   219|                        .font(.caption2).foregroundColor(.secondary)
   220|                }
   221|
   222|                Spacer()
   223|
   224|                // Expand/collapse indicator
   225|                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
   226|                    .font(.caption2)
   227|                    .foregroundColor(.secondary)
   228|                    .padding(6)
   229|                    .background(Circle().fill(Color.secondary.opacity(0.08)))
   230|            }
   231|
   232|            // Title — markdown-aware
   233|            MarkdownText(text: article.title)
   234|                .font(.body).fontWeight(.semibold)
   235|                .foregroundColor(.primary)
   236|                .lineLimit(isExpanded ? nil : 2)
   237|                .padding(.top, 10)
   238|
            // Summary — full text, cleaned by displaySummary
            if !article.displaySummary.isEmpty {
                Text(article.displaySummary)
                    .font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
   254|            }
   255|
   256|            // Tags
   257|            if !article.tags.isEmpty {
   258|                ScrollView(.horizontal, showsIndicators: false) {
   259|                    HStack(spacing: 6) {
   260|                        ForEach(article.tags.prefix(isExpanded ? article.tags.count : 4), id: \.self) { tag in
   261|                            Text(tag)
   262|                                .font(.caption2)
   263|                                .padding(.horizontal, 8).padding(.vertical, 3)
   264|                                .background(sourceColor(article.source).opacity(0.08))
   265|                                .foregroundColor(sourceColor(article.source))
   266|                                .cornerRadius(6)
   267|                        }
   268|                    }
   269|                }
   270|                .padding(.top, 8)
   271|            }
   272|
   273|            // Expanded content
   274|            if isExpanded {
   275|                VStack(alignment: .leading, spacing: 10) {
   276|                    Divider()
   277|
                    // URL button — safe unwrap
                    if let validURL = URL(string: article.url), !article.url.isEmpty {
   291|                        Button {
   292|                            #if os(macOS)
   293|                            NSWorkspace.shared.open(validURL)
   294|                            #else
   295|                            UIApplication.shared.open(validURL)
   296|                            #endif
   297|                        } label: {
   298|                            HStack {
   299|                                Image(systemName: "safari")
   300|                                Text(article.url)
   301|                                    .lineLimit(1)
   302|                                    .truncationMode(.middle)
   303|                                Spacer()
   304|                                Image(systemName: "arrow.up.forward")
   305|                            }
   306|                            .font(.caption)
   307|                            .padding(.horizontal, 12)
   308|                            .padding(.vertical, 8)
   309|                            .background(sourceColor(article.source).opacity(0.1))
   310|                            .cornerRadius(8)
   311|                            .overlay(
   312|                                RoundedRectangle(cornerRadius: 8)
   313|                                    .stroke(sourceColor(article.source).opacity(0.2), lineWidth: 0.5)
   314|                            )
   315|                        }
   316|                        .buttonStyle(.plain)
   317|                    }
   318|                }
   319|                .transition(.opacity.combined(with: .move(edge: .top)))
   320|            }
   321|
   322|            // Bottom action bar
   323|            HStack(spacing: 24) {
   324|                // Read / Open link — safe URL
   325|                if let validURL = URL(string: article.url), !article.url.isEmpty {
   326|                    Button {
   327|                        #if os(macOS)
   328|                        NSWorkspace.shared.open(validURL)
   329|                        #else
   330|                        UIApplication.shared.open(validURL)
   331|                        #endif
   332|                    } label: {
   333|                        HStack(spacing: 4) {
   334|                            Image(systemName: "safari").font(.caption2)
   335|                            Text("Open").font(.caption2)
   336|                        }
   337|                    }
   338|                    .buttonStyle(.plain)
   339|                    .foregroundColor(sourceColor(article.source))
   340|                }
   341|
   342|                // Expand/collapse
   343|                Button {
   344|                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
   345|                } label: {
   346|                    HStack(spacing: 4) {
   347|                        Image(systemName: isExpanded ? "chevron.up" : "text.justify.leading")
   348|                            .font(.caption2)
   349|                        Text(isExpanded ? "Less" : "More").font(.caption2)
   350|                    }
   351|                }
   352|                .buttonStyle(.plain)
   353|                .foregroundColor(.secondary)
   354|
   355|                Spacer()
   356|            }
   357|            .padding(.top, article.displaySummary.isEmpty && article.tags.isEmpty ? 6 : 10)
   358|        }
   359|        .padding(16)
   360|        .background(
   361|            RoundedRectangle(cornerRadius: 16)
   362|                .fill(Theme.surface)
   363|        )
   364|        .overlay(
   365|            RoundedRectangle(cornerRadius: 16)
   366|                .stroke(Color.secondary.opacity(0.08), lineWidth: 0.5)
   367|        )
   368|        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
   369|        .contentShape(Rectangle())
   370|        .onTapGesture {
   371|            withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
   372|        }
   373|    }
   374|
   375|    private func sourceColor(_ s: String) -> Color {
   376|        switch s {
   377|        case "arxiv": return .blue
   378|        case "github": return .purple
   379|        case "blog": return .orange
   380|        case "twitter": return .cyan
   381|        default: return .gray
   382|        }
   383|    }
   384|}
   385|