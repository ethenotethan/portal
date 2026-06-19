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

    private let pageSize = 200 // Server max: digest_store caps at 200
    private var totalCount = 0
    /// IDs already rendered, across all loaded pages. Used to de-collide
    /// duplicate article IDs from the backend (see uniquified(_:)).
    private var seenIDs: Set<String> = []

    var hasMore: Bool { articles.count < totalCount }

    func loadFeed(client: GatewayClient) async {
        guard !isLoading else { return }
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            let srcResp = try await client.feedSources()
            sourceCounts = srcResp.sources
            let feed = try await client.feedGet(sources: selectedSource.flatMap { [$0] }, limit: pageSize)
            seenIDs.removeAll()
            self.articles = uniquified(feed.articles); self.totalCount = feed.total
            log.info("Feed loaded: \(feed.articles.count) articles (total: \(feed.total))")
            // Auto-fetch remaining pages so user sees everything without manual scroll-triggered loads
            if hasMore {
                Task { await self.loadRemaining(client: client) }
            }
        } catch { log.error("feed.get failed: \(error.localizedDescription)"); self.error = error.localizedDescription }
    }

    func refresh(client: GatewayClient) async { articles = []; totalCount = 0; seenIDs.removeAll(); await loadFeed(client: client) }

    func loadMore(client: GatewayClient) async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true; defer { isLoadingMore = false }
        do {
            let feed = try await client.feedGet(sources: selectedSource.flatMap { [$0] }, limit: pageSize, offset: self.articles.count)
            self.articles.append(contentsOf: uniquified(feed.articles)); self.totalCount = feed.total
            log.info("Feed loaded more: now \(self.articles.count) / \(self.totalCount) articles")
        } catch { log.error("feed.get (more) failed: \(error.localizedDescription)") }
    }

    /// Guarantees every rendered article has a unique `id`.
    ///
    /// The digest backend can emit several articles sharing one id (e.g. a
    /// batch of tweets, which have no title — the server's id hash collapses
    /// them). SwiftUI's `ForEach` keys on `Identifiable.id`, so duplicates are
    /// silently dropped and 27 captured tweets render as 1. Suffix any repeat
    /// id with an incrementing counter so all of them survive. Harmless once
    /// the server emits unique ids — there are simply no collisions to fix.
    private func uniquified(_ incoming: [FeedArticle]) -> [FeedArticle] {
        var result: [FeedArticle] = []
        result.reserveCapacity(incoming.count)
        for article in incoming {
            guard seenIDs.contains(article.id) else {
                seenIDs.insert(article.id)
                result.append(article)
                continue
            }
            var suffix = 2
            var newID = "\(article.id)#\(suffix)"
            while seenIDs.contains(newID) {
                suffix += 1
                newID = "\(article.id)#\(suffix)"
            }
            seenIDs.insert(newID)
            result.append(article.withID(newID))
        }
        return result
    }

    private func loadRemaining(client: GatewayClient) async {
        while hasMore, !isLoading, !isLoadingMore {
            await loadMore(client: client)
        }
    }

    func selectSource(_ source: String?, client: GatewayClient) {
        guard selectedSource != source else { selectedSource = nil; Task { await refresh(client: client) }; return }
        selectedSource = source; Task { await refresh(client: client) }
    }
}
