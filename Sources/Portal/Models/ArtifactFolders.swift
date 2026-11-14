import Foundation

/// Which slice of the artifact list a surface shows: everything, one folder,
/// or the artifacts no one has filed. `RawRepresentable` so the choice
/// survives a relaunch through `@AppStorage`.
internal enum ArtifactFolderSelection: Hashable, RawRepresentable {
    case all
    case unfiled
    case folder(String)

    private static let folderPrefix = "folder:"

    internal init(rawValue: String) {
        if rawValue == "unfiled" {
            self = .unfiled
        } else if rawValue.hasPrefix(Self.folderPrefix) {
            let name = String(rawValue.dropFirst(Self.folderPrefix.count))
            self = name.isEmpty ? .all : .folder(name)
        } else {
            self = .all
        }
    }

    internal var rawValue: String {
        switch self {
        case .all: return "all"
        case .unfiled: return "unfiled"
        case .folder(let name): return Self.folderPrefix + name
        }
    }
}

/// The folders a set of artifacts is filed under, with counts — what the
/// folder strip draws and what a selection is checked against. A folder
/// exists exactly as long as an artifact is filed in it; there is no empty
/// folder to manage.
internal struct ArtifactFolderIndex: Equatable {
    internal struct Folder: Equatable, Identifiable {
        internal let name: String
        internal let count: Int
        internal var id: String { name }
    }

    /// Longest folder name the gateway stores (`MAX_CATEGORY_CHARS`).
    internal static let maxNameLength = 64

    /// Sorted by name, case-insensitively.
    internal let folders: [Folder]
    internal let unfiledCount: Int
    internal let totalCount: Int

    /// `categories` holds one entry per artifact, "" for an unfiled one.
    /// Names that differ only in case are one folder, spelled as first seen —
    /// the gateway converges spellings on write; a stale disk cache may not
    /// have caught up.
    internal init(categories: [String]) {
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        var unfiled = 0
        for category in categories {
            if category.isEmpty {
                unfiled += 1
                continue
            }
            let key = Self.key(category)
            counts[key, default: 0] += 1
            if spelling[key] == nil { spelling[key] = category }
        }
        folders = counts
            .map { key, count in Folder(name: spelling[key] ?? key, count: count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        unfiledCount = unfiled
        totalCount = categories.count
    }

    internal init(artifacts: [LivingArtifact]) {
        self.init(categories: artifacts.map(\.category))
    }

    internal var names: [String] { folders.map(\.name) }

    /// No folders yet: the surface shows the plain list, with no strip.
    internal var isEmpty: Bool { folders.isEmpty }

    /// The selection a surface should act on: a remembered folder that no
    /// longer holds anything (its last artifact was moved or deleted), or
    /// "Unfiled" once everything is filed, falls back to everything.
    internal func resolve(_ selection: ArtifactFolderSelection) -> ArtifactFolderSelection {
        switch selection {
        case .all:
            return .all
        case .unfiled:
            return unfiledCount > 0 && !isEmpty ? .unfiled : .all
        case .folder(let name):
            let key = Self.key(name)
            return folders.first { Self.key($0.name) == key }.map { .folder($0.name) } ?? .all
        }
    }

    /// Whether an artifact filed under `category` belongs to `selection`.
    internal static func contains(_ category: String, in selection: ArtifactFolderSelection) -> Bool {
        switch selection {
        case .all: return true
        case .unfiled: return category.isEmpty
        case .folder(let name): return !category.isEmpty && key(category) == key(name)
        }
    }

    /// The stored form of a typed folder name, mirroring the gateway's
    /// `normalize_category`: outer whitespace dropped, inner runs collapsed,
    /// control characters removed, capped at the gateway's length.
    internal static func normalize(_ raw: String) -> String {
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control ? " " : scalar
        }))
        let collapsed = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    private static func key(_ name: String) -> String { name.lowercased() }
}

extension Array where Element == LivingArtifact {
    /// The artifacts a folder selection shows, order preserved.
    internal func filed(under selection: ArtifactFolderSelection) -> [LivingArtifact] {
        if selection == .all { return self }
        return filter { ArtifactFolderIndex.contains($0.category, in: selection) }
    }
}
