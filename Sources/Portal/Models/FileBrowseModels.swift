import Foundation

// Wire models for the gateway's read-only file browser (`files.list` /
// `files.read`). The gateway exposes two allowlisted roots — `repo` (the
// running Hermes checkout) and `hermes` (~/.hermes) — as a lazily-walked,
// containment-checked tree. See harness docs/api/files-browse.md.

/// One entry in a directory listing: a file or a subdirectory.
internal struct FileEntry: Identifiable, Hashable {
    /// The browsable root this entry lives under (`repo` / `hermes`).
    internal let root: String
    /// Path relative to the root (e.g. `indexing/x402_snapshot.py`).
    internal let path: String
    /// Leaf name for display.
    internal let name: String
    internal let isDirectory: Bool
    /// Byte size for files; 0 for directories.
    internal let size: Int
    /// Directories only: whether expanding will yield anything (drives the
    /// disclosure arrow without a speculative round-trip).
    internal let hasChildren: Bool

    /// Stable across roots — the same relative path in `repo` and `hermes`
    /// must not collide in a ForEach/selection set.
    internal var id: String { "\(root):\(path)" }

    internal static func from(_ dict: [String: AnyCodable], root: String) -> FileEntry? {
        guard let name = dict["name"]?.stringValue,
              let path = dict["path"]?.stringValue,
              let type = dict["type"]?.stringValue else { return nil }
        let isDir = type == "dir"
        return FileEntry(
            root: root,
            path: path,
            name: name,
            isDirectory: isDir,
            size: dict["size"]?.intValue ?? 0,
            hasChildren: isDir ? (dict["has_children"]?.boolValue ?? false) : false
        )
    }
}

/// The result of listing one directory level under a root.
internal struct FileListing {
    internal let root: String
    /// Absolute path of the root on the gateway host (for display only).
    internal let rootPath: String
    /// The relative directory that was listed (empty = the root itself).
    internal let path: String
    internal let entries: [FileEntry]

    internal static func from(_ dict: [String: AnyCodable], requestedRoot: String) -> FileListing {
        let root = dict["root"]?.stringValue ?? requestedRoot
        let entries = (dict["entries"]?.arrayValue ?? []).compactMap {
            $0.dictionaryValue.flatMap { FileEntry.from($0, root: root) }
        }
        return FileListing(
            root: root,
            rootPath: dict["root_path"]?.stringValue ?? "",
            path: dict["path"]?.stringValue ?? "",
            entries: entries
        )
    }
}

/// A single read-only file's contents plus display metadata.
internal struct FileContent {
    internal let root: String
    internal let path: String
    internal let content: String
    internal let size: Int
    /// Server-reported writability (`os.access(W_OK)`); the desktop is
    /// read-only regardless, but this labels why.
    internal let readOnly: Bool
    /// Extension hint (e.g. `py`, `md`) for the syntax highlighter.
    internal let language: String

    /// Files whose language maps to Markdown render as prose, not code.
    internal var isMarkdown: Bool { language == "md" || language == "markdown" }

    /// Leaf name for the reader header.
    internal var fileName: String { (path as NSString).lastPathComponent }

    internal static func from(_ dict: [String: AnyCodable], requestedRoot: String, requestedPath: String) -> FileContent {
        FileContent(
            root: dict["root"]?.stringValue ?? requestedRoot,
            path: dict["path"]?.stringValue ?? requestedPath,
            content: dict["content"]?.stringValue ?? "",
            size: dict["size"]?.intValue ?? 0,
            readOnly: dict["read_only"]?.boolValue ?? true,
            language: dict["language"]?.stringValue ?? ""
        )
    }
}
