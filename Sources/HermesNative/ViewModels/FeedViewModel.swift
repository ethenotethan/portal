import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "FeedViewModel")

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var articles: [FeedArticle] = []
    @Published var sourceCounts: [String: Int] = [:]
    @Published var selectedSource: String?
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var error: String?

    private let pageSize = 50
    private var totalCount = 0

    var hasMore: Bool { articles.count < totalCount }

    func loadFeed(client: GatewayClient) async {
        guard !isLoading else { return }
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            let srcResp = try await client.feedSources()
            sourceCounts = srcResp.sources
            let feed = try await client.feedGet(sources: selectedSource.flatMap { [$0] }, limit: pageSize)
            self.articles = feed.articles; self.totalCount = feed.total
            log.info("Feed loaded: \(feed.articles.count) articles (total: \(feed.total))")
        } catch { log.error("feed.get failed: \(error.localizedDescription)"); self.error = error.localizedDescription }
    }

    func refresh(client: GatewayClient) async { articles = []; totalCount = 0; await loadFeed(client: client) }

    func loadMore(client: GatewayClient) async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true; defer { isLoadingMore = false }
        do {
            let feed = try await client.feedGet(sources: selectedSource.flatMap { [$0] }, limit: pageSize, offset: self.articles.count)
            self.articles.append(contentsOf: feed.articles); self.totalCount = feed.total
            log.info("Feed loaded more: now \(self.articles.count) / \(self.totalCount) articles")
        } catch { log.error("feed.get (more) failed: \(error.localizedDescription)") }
    }

    func selectSource(_ source: String?, client: GatewayClient) {
        guard selectedSource != source else { selectedSource = nil; Task { await refresh(client: client) }; return }
        selectedSource = source; Task { await refresh(client: client) }
    }
}
