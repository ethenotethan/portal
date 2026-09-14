import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CronSourceFilesViewModel")

/// The two reads the explorer needs from the gateway's file browser. A protocol
/// so the view model never names the concrete client and a test can hand it a
/// stub — the same split `HermesStandardCronManaging` gives the cron list.
@MainActor
internal protocol CronSourceFileReading: AnyObject {
    func readFile(root: String, path: String) async throws -> FileContent
    func listFiles(root: String, path: String) async throws -> FileListing
}

extension GatewayClient: CronSourceFileReading {}

/// Drives the source-file explorer beside the cron graph: the file open in the
/// reader pane, and the lazily listed folders around a job's files.
///
/// Reads go through the same `files.list` / `files.read` the Files tab uses,
/// so a script is only openable when it sits under a browsable root — which
/// the gateway already decided per file (`CronSourceFile.root`). Listing a
/// file's folder is what turns a flat list of declared paths into an explorer:
/// the helper module next to the script is one disclosure away, without
/// leaving the graph.
@MainActor
internal final class CronSourceFilesViewModel: ObservableObject {
    /// The contents in the reader, or nil when the pane is closed.
    @Published internal private(set) var openFile: FileContent?
    /// Which file the reader is showing — drives row highlight and the header's
    /// role badge. Set before the read returns so the pane can open on a spinner.
    @Published internal private(set) var openSource: CronSourceFile?
    @Published internal private(set) var isLoadingFile = false
    @Published internal private(set) var errorMessage: String?

    /// Listed folder contents keyed `root:dir`; absent = not yet fetched.
    @Published internal private(set) var childrenByKey: [String: [FileEntry]] = [:]
    /// Folders the user has disclosed (drives the arrow + lazy load).
    @Published internal private(set) var expandedKeys: Set<String> = []
    @Published internal private(set) var loadingKeys: Set<String> = []
    /// Absolute path per root name, learned from listings — lets a sibling
    /// reached through a folder get the same absolute-path identity the
    /// gateway gives a declared file.
    private var rootPaths: [String: String] = [:]

    private var client: (any CronSourceFileReading)?
    /// Identity of the newest read: a person clicking down the list outruns
    /// the network, and a late response for a file no longer asked for must
    /// not land in the pane.
    private var readGeneration = 0

    internal func setClient(_ client: any CronSourceFileReading) { self.client = client }

    internal static func key(root: String, path: String) -> String { "\(root):\(path)" }

    /// Whether the reader pane has anything to show (a file, or a read in
    /// flight for one).
    internal var isPresentingReader: Bool { openSource != nil }

    // MARK: - Reader

    /// Open a source file the graph listed. A file outside every browsable root
    /// can't be read by the gateway, so that is reported rather than attempted.
    internal func open(_ file: CronSourceFile) async {
        guard let root = file.root, let rel = file.relativePath else {
            errorMessage = "\(file.fileName) is outside the browsable roots, so the gateway can't read it."
            return
        }
        guard let client else { return }
        readGeneration += 1
        let generation = readGeneration
        openSource = file
        openFile = nil
        isLoadingFile = true
        do {
            let content = try await client.readFile(root: root, path: rel)
            guard generation == readGeneration else { return }
            openFile = content
            errorMessage = nil
        } catch {
            guard generation == readGeneration else { return }
            log.error("files.read \(root):\(rel) failed: \(error)")
            openFile = nil
            errorMessage = Self.friendly(error)
        }
        isLoadingFile = false
    }

    /// Open a neighbour reached through a folder listing — the same reader,
    /// with the file described the way a declared one is so the header reads
    /// consistently. Its role is `browsed`: nothing on the job named it.
    internal func open(entry: FileEntry) async {
        guard !entry.isDirectory else { return }
        await open(Self.sourceFile(for: entry, rootPath: rootPaths[entry.root]))
    }

    /// A `CronSourceFile` standing in for a listed entry. The absolute path is
    /// composed from the root's path when a listing has told us it; before that
    /// the `root:rel` pair is the identity, which is still unique.
    nonisolated internal static func sourceFile(for entry: FileEntry, rootPath: String?) -> CronSourceFile {
        let absolute: String
        if let rootPath, !rootPath.isEmpty {
            absolute = (rootPath as NSString).appendingPathComponent(entry.path)
        } else {
            absolute = "\(entry.root):\(entry.path)"
        }
        return CronSourceFile(
            path: absolute,
            declared: entry.path,
            role: "browsed",
            root: entry.root,
            relativePath: entry.path,
            exists: true
        )
    }

    /// Close the reader. Also retires any read still in flight.
    internal func close() {
        readGeneration += 1
        openSource = nil
        openFile = nil
        isLoadingFile = false
        errorMessage = nil
    }

    // MARK: - Folders

    internal func children(root: String, path: String) -> [FileEntry]? {
        childrenByKey[Self.key(root: root, path: path)]
    }

    internal func isExpanded(root: String, path: String) -> Bool {
        expandedKeys.contains(Self.key(root: root, path: path))
    }

    internal func isLoading(root: String, path: String) -> Bool {
        loadingKeys.contains(Self.key(root: root, path: path))
    }

    /// Toggle a folder: collapsing just hides; expanding fetches its children
    /// on first open and keeps them for the next.
    internal func toggleFolder(root: String, path: String) async {
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
            if !listing.rootPath.isEmpty { rootPaths[root] = listing.rootPath }
            childrenByKey[key] = listing.entries
            errorMessage = nil
        } catch {
            // Drop the optimistic expansion so the arrow doesn't sit open-empty.
            expandedKeys.remove(key)
            log.error("files.list \(root):\(path) failed: \(error)")
            errorMessage = Self.friendly(error)
        }
    }

    private static func friendly(_ error: Error) -> String {
        if case let GatewayError.rpcError(rpc) = error {
            return rpc.message
        }
        return error.localizedDescription
    }
}
