import SwiftUI
import os.log

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "WikiTimelineViewModel")

/// Drives the wiki changeset timeline: paginated fetch + action filter.
@MainActor
final class WikiTimelineViewModel: ObservableObject {

    @Published private(set) var changesets: [WikiChangeset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var total = 0

    /// Active action filter (nil = all).
    @Published var actionFilter: WikiChangeset.Action? {
        didSet {
            guard oldValue != actionFilter else { return }
            Task { await reload() }
        }
    }

    /// Filter to a single page's history (nil = whole wiki).
    private(set) var pageFilter: String?

    private let pageSize = 50
    private var wiki: String?
    private var loadGeneration = 0

    var hasMore: Bool { changesets.count < total }

    /// Configure the filters without yet fetching. Call `reload(client:)` after.
    func configure(wiki: String?, page: String? = nil) {
        self.wiki = wiki
        self.pageFilter = page
    }

    /// Fetch the first page, replacing current contents.
    func reload(client: GatewayClient?) async {
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let result = try await client.wikiChangesets(
                wiki: wiki,
                page: pageFilter,
                action: actionFilter?.rawValue,
                limit: pageSize,
                offset: 0
            )
            guard generation == loadGeneration else { return }
            changesets = result.changesets
            total = result.total
        } catch {
            guard generation == loadGeneration else { return }
            log.error("wiki.changesets failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    /// Re-fetch using the last-used client (filter changes call this).
    private var lastClient: GatewayClient?
    func reload() async {
        await reload(client: lastClient)
    }

    /// Fetch the next page and append.
    func loadMore(client: GatewayClient?) async {
        guard let client, !isLoadingMore, hasMore else { return }
        lastClient = client
        let generation = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let result = try await client.wikiChangesets(
                wiki: wiki,
                page: pageFilter,
                action: actionFilter?.rawValue,
                limit: pageSize,
                offset: changesets.count
            )
            guard generation == loadGeneration else { return }
            // Guard against duplicates if the list shifted between fetches.
            let existing = Set(changesets.map(\.id))
            changesets.append(contentsOf: result.changesets.filter { !existing.contains($0.id) })
            total = result.total
        } catch {
            log.error("wiki.changesets loadMore failed: \(error.localizedDescription)")
        }
    }

    /// Convenience wrapper that stashes the client for filter-triggered reloads.
    func start(client: GatewayClient?) async {
        lastClient = client
        await reload(client: client)
    }

    // MARK: - Inline diffs

    /// Fetch state for a changeset's git-style diff, keyed by changeset id
    /// (the inline expansion under a timeline row reads this).
    struct DiffState {
        var diff: String?
        var errorMessage: String?
        var isLoading = true
    }

    @Published private(set) var diffStates: [String: DiffState] = [:]

    /// Load a changeset's unified diff for inline display. Cached per id;
    /// re-expanding a row is free. `force` drops the cache (error retry).
    func loadDiff(client: GatewayClient?, changesetID: String, force: Bool = false) async {
        guard let client else { return }
        if !force, let state = diffStates[changesetID], !state.isLoading { return }
        diffStates[changesetID] = DiffState(isLoading: true)
        do {
            let diff = try await client.wikiChangesetDiff(id: changesetID, wiki: wiki)
            diffStates[changesetID] = DiffState(diff: diff, isLoading: false)
        } catch let GatewayError.rpcError(rpcError) {
            // 5057 = wiki not git-initialized at capture time; anything else
            // (older gateway without the RPC, transient) reads the same way.
            diffStates[changesetID] = DiffState(errorMessage: rpcError.message, isLoading: false)
        } catch {
            diffStates[changesetID] = DiffState(errorMessage: error.localizedDescription, isLoading: false)
        }
    }
}
