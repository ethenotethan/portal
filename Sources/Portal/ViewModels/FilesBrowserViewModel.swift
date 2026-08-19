import Foundation

/// Drives the read-only Hermes file browser: a lazily-walked tree over the
/// gateway's `repo` and `hermes` roots plus the currently-open file.
///
/// The gateway lists one directory level per call, so the tree fills in as
/// folders expand — `childrenByKey` caches each level keyed by `root:path`,
/// and a folder is fetched exactly once (on first expand) unless explicitly
/// refreshed. This keeps every round-trip bounded and any path reachable no
/// matter how large the checkout is.
@MainActor
internal final class FilesBrowserViewModel: ObservableObject {
    /// Available root names (e.g. `["hermes", "repo"]`), sorted by the server.
    @Published internal private(set) var roots: [String] = []
    /// Listed children per `root:path`. Absent = not yet fetched.
    @Published internal private(set) var childrenByKey: [String: [FileEntry]] = [:]
    /// Directories the user has expanded (drives disclosure state + lazy load).
    @Published internal private(set) var expandedKeys: Set<String> = []
    /// Keys with an in-flight listing, for per-folder spinners.
    @Published internal private(set) var loadingKeys: Set<String> = []

    @Published internal private(set) var selectedFile: FileContent?
    /// `FileEntry.id` of the selected file, for row highlighting.
    @Published internal private(set) var selectedID: String?
    @Published internal private(set) var isLoadingFile = false

    @Published internal private(set) var rootsLoaded = false
    @Published internal var errorMessage: String?

    private var client: GatewayClient?

    internal func setClient(_ client: GatewayClient) { self.client = client }

    internal static func key(root: String, path: String) -> String { "\(root):\(path)" }

    internal func children(root: String, path: String) -> [FileEntry]? {
        childrenByKey[Self.key(root: root, path: path)]
    }

    internal func isExpanded(root: String, path: String) -> Bool {
        expandedKeys.contains(Self.key(root: root, path: path))
    }

    internal func isLoading(root: String, path: String) -> Bool {
        loadingKeys.contains(Self.key(root: root, path: path))
    }

    /// Load the root set. Idempotent-friendly: safe to call from `.task`.
    internal func loadRoots() async {
        guard let client else { return }
        do {
            let names = try await client.fileRoots()
            roots = names
            rootsLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = Self.friendly(error)
            rootsLoaded = true
        }
    }

    /// Toggle a directory: collapsing just hides; expanding fetches its
    /// children on first open.
    internal func toggleDirectory(root: String, path: String) async {
        let key = Self.key(root: root, path: path)
        if expandedKeys.contains(key) {
            expandedKeys.remove(key)
            return
        }
        expandedKeys.insert(key)
        if childrenByKey[key] == nil {
            await loadChildren(root: root, path: path)
        }
    }

    private func loadChildren(root: String, path: String) async {
        guard let client else { return }
        let key = Self.key(root: root, path: path)
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }
        do {
            let listing = try await client.listFiles(root: root, path: path)
            childrenByKey[key] = listing.entries
            errorMessage = nil
        } catch {
            // Drop the optimistic expansion so the arrow doesn't sit open-empty.
            expandedKeys.remove(key)
            errorMessage = Self.friendly(error)
        }
    }

    /// Open a file into the reader pane.
    internal func select(_ entry: FileEntry) async {
        guard let client, !entry.isDirectory else { return }
        selectedID = entry.id
        isLoadingFile = true
        defer { isLoadingFile = false }
        do {
            selectedFile = try await client.readFile(root: entry.root, path: entry.path)
            errorMessage = nil
        } catch {
            errorMessage = Self.friendly(error)
            selectedFile = nil
        }
    }

    /// Close the reader (the compact-width back action).
    internal func clearSelection() {
        selectedFile = nil
        selectedID = nil
    }

    private static func friendly(_ error: Error) -> String {
        if case let GatewayError.rpcError(rpc) = error {
            return rpc.message
        }
        return error.localizedDescription
    }
}
