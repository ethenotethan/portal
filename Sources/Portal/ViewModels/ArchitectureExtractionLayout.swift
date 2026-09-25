import Foundation

// MARK: - Layout of the Extraction map (pure, deterministic)

/// Everything the Extraction map renderer needs computed, with no SwiftUI in
/// it: the folded directory tree, the visible rows of both columns for a set of
/// open directories and entity kinds, the wire bundles between them, what a
/// selection highlights, the squarified treemap, and the three tables. The view
/// only draws what comes out of here, so all of it is unit-testable.
internal enum ArchitectureExtractionLayout {

    // MARK: Metrics

    internal enum Metrics {
        internal static let rowHeight: Double = 20
        internal static let indent: Double = 14
        internal static let leftColumnWidth: Double = 380
        internal static let rightColumnWidth: Double = 340
        internal static let minimumWireSpan: Double = 240
        internal static let treemapHeader: Double = 16
        internal static let treemapPadding: Double = 3
    }

    // MARK: Directory tree

    /// A directory in the folded tree: single-child chains are one node whose
    /// name is the joined path, so `Sources/Portal` reads as one shell.
    internal struct DirectoryNode: Hashable {
        internal let name: String
        internal let path: String
        internal let depth: Int
        internal let directories: [DirectoryNode]
        internal let files: [ArchitectureExtractedFile]
        internal let lines: Int

        /// Every file under this directory, transitively.
        internal var allFiles: [ArchitectureExtractedFile] {
            files + directories.flatMap(\.allFiles)
        }

        /// This node and every directory below it, depth-first in display order.
        internal var allDirectories: [DirectoryNode] {
            [self] + directories.flatMap(\.allDirectories)
        }
    }

    private final class MutableDirectory {
        internal let name: String
        internal var children: [String: MutableDirectory] = [:]
        internal var files: [ArchitectureExtractedFile] = []

        internal init(name: String) {
            self.name = name
        }
    }

    /// The folded directory tree of the analysed files. The root's path is the
    /// empty string and its label is "repository".
    internal static func tree(files: [ArchitectureExtractedFile]) -> DirectoryNode {
        let root = MutableDirectory(name: "")
        for file in files {
            var node = root
            for part in file.path.split(separator: "/").dropLast().map(String.init) {
                if let child = node.children[part] {
                    node = child
                } else {
                    let child = MutableDirectory(name: part)
                    node.children[part] = child
                    node = child
                }
            }
            node.files.append(file)
        }
        return fold(root, parentPath: "", depth: 0)
    }

    private static func fold(_ node: MutableDirectory, parentPath: String, depth: Int) -> DirectoryNode {
        var current = node
        var labels = [current.name]
        while current.children.count == 1, current.files.isEmpty, let only = current.children.values.first {
            current = only
            labels.append(current.name)
        }
        let name = labels.filter { !$0.isEmpty }.joined(separator: "/")
        let path = parentPath.isEmpty ? name : (name.isEmpty ? parentPath : "\(parentPath)/\(name)")
        let directories = current.children.values
            .map { fold($0, parentPath: path, depth: depth + 1) }
            .sorted { left, right in left.lines != right.lines ? left.lines > right.lines : left.name < right.name }
        let files = current.files.sorted { left, right in
            left.lineCount != right.lineCount ? left.lineCount > right.lineCount : left.path < right.path
        }
        let lines = directories.reduce(0) { $0 + $1.lines } + files.reduce(0) { $0 + $1.lineCount }
        return DirectoryNode(name: name, path: path, depth: depth, directories: directories, files: files, lines: lines)
    }

    /// The outermost shells start open: the root and its first-level directories.
    internal static func defaultOpenDirectories(_ root: DirectoryNode) -> Set<String> {
        Set(root.allDirectories.filter { $0.depth <= 1 }.map(\.path))
    }

    // MARK: Provenance index

    /// One wire's worth of provenance: the entity an origin belongs to.
    internal struct EntityOrigin: Hashable {
        internal let entityID: String
        internal let kind: String
        internal let label: String
        internal let origin: ArchitectureExtractionOrigin
    }

    /// Origins grouped by the file they were read from, each sorted by line.
    internal static func originsByFile(_ document: ArchitectureExtractionDocument) -> [String: [EntityOrigin]] {
        var byFile: [String: [EntityOrigin]] = [:]
        for entity in document.entities {
            for origin in entity.origins {
                byFile[origin.path, default: []].append(EntityOrigin(entityID: entity.id, kind: entity.kind, label: entity.label, origin: origin))
            }
        }
        for (path, origins) in byFile {
            byFile[path] = origins.sorted { left, right in
                left.origin.line != right.origin.line ? left.origin.line < right.origin.line : left.label < right.label
            }
        }
        return byFile
    }

    // MARK: Entity kinds

    internal static let kindOrder: [String] = [
        "endpoint", "client", "caller", "hub", "provider", "owner", "seam", "subscriber",
        "resource", "section", "operation", "machine", "store", "artifact", "external",
    ]

    private static let kindLabels: [String: String] = [
        "endpoint": "Endpoints (RPC namespaces)", "client": "Client extensions", "caller": "Calling surfaces",
        "hub": "Interplay hub", "provider": "Config provider", "owner": "Supporting owners", "seam": "Backend seam",
        "subscriber": "Event subscribers", "resource": "Stored resources", "section": "Critical sections",
        "operation": "Lifecycle operations", "machine": "State machines", "store": "Data stores",
        "artifact": "Persisted artifacts", "external": "External systems",
    ]

    internal static func kindLabel(_ kind: String) -> String {
        kindLabels[kind] ?? kind
    }

    /// The kinds present in a document, known ones in contract order, then the rest alphabetically.
    internal static func kinds(in document: ArchitectureExtractionDocument) -> [String] {
        let present = Set(document.entities.map(\.kind))
        let known = kindOrder.filter { present.contains($0) }
        let unknown = present.subtracting(kindOrder).sorted()
        return known + unknown
    }

    // MARK: Search

    /// Case-insensitive match of a file against a query: its path, an entity it
    /// produced, a rule that fired in it, or a declaration name.
    internal static func fileMatches(_ file: ArchitectureExtractedFile, query: String, origins: [String: [EntityOrigin]]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        if file.path.lowercased().contains(needle) { return true }
        if file.passes.contains(where: { $0.lowercased().contains(needle) }) { return true }
        if file.declarations.contains(where: { $0.name.lowercased().contains(needle) }) { return true }
        return (origins[file.path] ?? []).contains { $0.label.lowercased().contains(needle) || $0.origin.rule.lowercased().contains(needle) }
    }

    /// Case-insensitive match of an entity: its label, kind, a rule or a file it came from.
    internal static func entityMatches(_ entity: ArchitectureExtractedEntity, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        if entity.label.lowercased().contains(needle) || entity.kind.lowercased().contains(needle) { return true }
        return entity.origins.contains { $0.rule.lowercased().contains(needle) || $0.path.lowercased().contains(needle) }
    }

    // MARK: Rows

    internal enum LeftRowKind: Hashable {
        case directory
        case file
    }

    /// A row of the file schema column.
    internal struct LeftRow: Hashable, Identifiable {
        internal let kind: LeftRowKind
        internal let key: String
        internal let label: String
        internal let depth: Int
        internal let isOpen: Bool
        /// Files this row stands for: itself for a file, every file beneath for a closed directory.
        internal let filePaths: [String]
        /// How many of those files feed the map.
        internal let wiredFiles: Int
        /// For a file row, the number of extractions leaving it.
        internal let originCount: Int
        internal let declarationCount: Int
        internal let matches: Bool

        internal var id: String { key }
        internal var isUntouchedFile: Bool { kind == .file && originCount == 0 }
    }

    internal enum RightRowKind: Hashable {
        case entityKind
        case entity
    }

    /// A row of the entities column.
    internal struct RightRow: Hashable, Identifiable {
        internal let kind: RightRowKind
        internal let key: String
        internal let label: String
        internal let isOpen: Bool
        /// Entities this row stands for: itself, or every entity of a closed kind.
        internal let entityIDs: [String]
        internal let originCount: Int
        internal let matches: Bool

        internal var id: String { key }
    }

    internal struct Rows: Hashable {
        internal let left: [LeftRow]
        internal let right: [RightRow]

        internal var count: Int { max(left.count, right.count) }
    }

    /// The visible rows of both columns for the current open sets and query.
    internal static func rows(
        document: ArchitectureExtractionDocument,
        tree root: DirectoryNode,
        openDirectories: Set<String>,
        openKinds: Set<String>,
        query: String,
        origins: [String: [EntityOrigin]]
    ) -> Rows {
        var left: [LeftRow] = []
        func visit(_ node: DirectoryNode) {
            let files = node.allFiles
            let isOpen = openDirectories.contains(node.path)
            left.append(LeftRow(
                kind: .directory,
                key: node.path,
                label: node.name.isEmpty ? "repository" : node.name,
                depth: node.depth,
                isOpen: isOpen,
                filePaths: files.map(\.path),
                wiredFiles: files.filter { !(origins[$0.path] ?? []).isEmpty }.count,
                originCount: files.reduce(0) { $0 + (origins[$1.path]?.count ?? 0) },
                declarationCount: files.reduce(0) { $0 + $1.declarationCount },
                matches: files.contains { fileMatches($0, query: query, origins: origins) }
            ))
            guard isOpen else { return }
            node.directories.forEach(visit)
            for file in node.files.sorted(by: { $0.path < $1.path }) {
                let fileOrigins = origins[file.path] ?? []
                left.append(LeftRow(
                    kind: .file,
                    key: file.path,
                    label: file.fileName,
                    depth: node.depth + 1,
                    isOpen: false,
                    filePaths: [file.path],
                    wiredFiles: fileOrigins.isEmpty ? 0 : 1,
                    originCount: fileOrigins.count,
                    declarationCount: file.declarationCount,
                    matches: fileMatches(file, query: query, origins: origins)
                ))
            }
        }
        visit(root)

        var right: [RightRow] = []
        for kind in kinds(in: document) {
            let entities = document.entities.filter { $0.kind == kind }
                .sorted { left, right in left.label != right.label ? left.label < right.label : left.id < right.id }
            let isOpen = openKinds.contains(kind)
            right.append(RightRow(
                kind: .entityKind,
                key: kind,
                label: kindLabel(kind),
                isOpen: isOpen,
                entityIDs: entities.map(\.id),
                originCount: entities.reduce(0) { $0 + $1.origins.count },
                matches: entities.contains { entityMatches($0, query: query) }
            ))
            guard isOpen else { continue }
            for entity in entities {
                right.append(RightRow(
                    kind: .entity,
                    key: entity.id,
                    label: entity.label,
                    isOpen: false,
                    entityIDs: [entity.id],
                    originCount: entity.origins.count,
                    matches: entityMatches(entity, query: query)
                ))
            }
        }
        return Rows(left: left, right: right)
    }

    // MARK: Wires

    /// Every origin between the rows that stand for its file and its entity,
    /// bundled: one bundle per (left row, right row) pair.
    internal struct WireBundle: Hashable {
        internal let sourceRow: Int
        internal let targetRow: Int
        internal let count: Int
        internal let families: Set<ArchitectureExtractionFamily>
        internal let filePaths: Set<String>
        internal let entityIDs: Set<String>

        /// The one family when every extraction in the bundle shares it; mixed bundles are drawn quiet.
        internal var family: ArchitectureExtractionFamily? {
            families.count == 1 ? families.first : nil
        }

        /// Stroke width grows with the number of extractions bundled.
        internal var width: Double {
            1 + log2(Double(max(1, count)))
        }
    }

    internal static func wires(document: ArchitectureExtractionDocument, rows: Rows) -> [WireBundle] {
        var leftRowForFile: [String: Int] = [:]
        for (index, row) in rows.left.enumerated() {
            if row.kind == .file {
                leftRowForFile[row.key] = index
            } else if !row.isOpen {
                for path in row.filePaths { leftRowForFile[path] = index }
            }
        }
        var rightRowForEntity: [String: Int] = [:]
        for (index, row) in rows.right.enumerated() {
            if row.kind == .entity || !row.isOpen {
                for id in row.entityIDs { rightRowForEntity[id] = index }
            }
        }
        struct Accumulator {
            var count = 0
            var families: Set<ArchitectureExtractionFamily> = []
            var files: Set<String> = []
            var entities: Set<String> = []
        }
        var bundles: [String: Accumulator] = [:]
        var keys: [(Int, Int)] = []
        for entity in document.entities {
            guard let target = rightRowForEntity[entity.id] else { continue }
            for origin in entity.origins {
                guard let source = leftRowForFile[origin.path] else { continue }
                let key = "\(source)→\(target)"
                if bundles[key] == nil { keys.append((source, target)) }
                var accumulator = bundles[key] ?? Accumulator()
                accumulator.count += 1
                accumulator.families.insert(origin.family)
                accumulator.files.insert(origin.path)
                accumulator.entities.insert(entity.id)
                bundles[key] = accumulator
            }
        }
        return keys.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.compactMap { source, target in
            guard let accumulator = bundles["\(source)→\(target)"] else { return nil }
            return WireBundle(
                sourceRow: source, targetRow: target, count: accumulator.count,
                families: accumulator.families, filePaths: accumulator.files, entityIDs: accumulator.entities
            )
        }
    }

    // MARK: Selection

    internal enum SelectionSide: Hashable {
        case file
        case entity
    }

    internal struct Selection: Hashable {
        internal let side: SelectionSide
        internal let key: String
    }

    /// The files and entities on the other end of the selection's wires (and the selection itself).
    internal struct Highlight: Hashable {
        internal let files: Set<String>
        internal let entities: Set<String>
    }

    internal static func highlight(
        for selection: Selection?,
        document: ArchitectureExtractionDocument,
        origins: [String: [EntityOrigin]]
    ) -> Highlight? {
        guard let selection else { return nil }
        switch selection.side {
        case .file:
            return Highlight(files: [selection.key], entities: Set((origins[selection.key] ?? []).map(\.entityID)))
        case .entity:
            let entity = document.entityByID[selection.key]
            return Highlight(files: Set(entity?.origins.map(\.path) ?? []), entities: [selection.key])
        }
    }

    internal static func isLinked(_ row: LeftRow, highlight: Highlight?) -> Bool {
        guard let highlight else { return false }
        return row.filePaths.contains { highlight.files.contains($0) }
    }

    internal static func isLinked(_ row: RightRow, highlight: Highlight?) -> Bool {
        guard let highlight else { return false }
        return row.entityIDs.contains { highlight.entities.contains($0) }
    }

    /// A bundle is on the selection when both its ends are highlighted.
    internal static func isSelected(_ bundle: WireBundle, highlight: Highlight?) -> Bool {
        guard let highlight else { return false }
        return !bundle.filePaths.isDisjoint(with: highlight.files) && !bundle.entityIDs.isDisjoint(with: highlight.entities)
    }

    /// A row is dimmed when a query excludes it or a selection does not reach it.
    internal static func isDimmed(matches: Bool, query: String, isSelected: Bool, isLinked: Bool, highlight: Highlight?) -> Bool {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty && !matches { return true }
        return highlight != nil && !isSelected && !isLinked
    }

    // MARK: Treemap

    /// Squarified treemap (Bruls, Huizing, van Wijk): weights laid into `rect`
    /// in order, rows along the shorter side, each row grown while its worst
    /// aspect ratio keeps improving. Zero and negative weights get empty rects.
    internal static func squarify(weights: [Double], in rect: CGRect) -> [CGRect] {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return weights.map { _ in CGRect(origin: rect.origin, size: .zero) }
        }
        let scale = Double(rect.width * rect.height) / total
        var result = Array(repeating: CGRect(origin: rect.origin, size: .zero), count: weights.count)
        var remaining = weights.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, area: $0.element * scale) }
        var x = Double(rect.minX)
        var y = Double(rect.minY)
        var w = Double(rect.width)
        var h = Double(rect.height)
        func worst(_ row: [(index: Int, area: Double)], side: Double, area: Double) -> Double {
            let thickness = area / side
            return row.map { entry in
                let length = entry.area / thickness
                return max(length / thickness, thickness / length)
            }.max() ?? .infinity
        }
        while !remaining.isEmpty {
            let vertical = w >= h
            let side = vertical ? h : w
            var row = [remaining[0]]
            var rowArea = remaining[0].area
            var ratio = worst(row, side: side, area: rowArea)
            var next = 1
            while next < remaining.count {
                let candidate = row + [remaining[next]]
                let candidateArea = rowArea + remaining[next].area
                let candidateRatio = worst(candidate, side: side, area: candidateArea)
                if candidateRatio > ratio { break }
                row = candidate
                rowArea = candidateArea
                ratio = candidateRatio
                next += 1
            }
            let thickness = side > 0 ? rowArea / side : 0
            var offset = 0.0
            for entry in row {
                let length = thickness > 0 ? entry.area / thickness : 0
                result[entry.index] = vertical
                    ? CGRect(x: x, y: y + offset, width: thickness, height: length)
                    : CGRect(x: x + offset, y: y, width: length, height: thickness)
                offset += length
            }
            if vertical {
                x += thickness
                w -= thickness
            } else {
                y += thickness
                h -= thickness
            }
            remaining.removeFirst(row.count)
        }
        return result
    }

    internal struct TreemapFrame: Hashable {
        internal let path: String
        internal let label: String
        internal let depth: Int
        internal let rect: CGRect
    }

    internal struct TreemapCell: Hashable {
        internal let file: ArchitectureExtractedFile
        internal let rect: CGRect
    }

    internal struct Treemap: Hashable {
        internal let frames: [TreemapFrame]
        internal let cells: [TreemapCell]

        /// The deepest cell under a point, or nil.
        internal func cell(at point: CGPoint) -> TreemapCell? {
            cells.last { $0.rect.contains(point) }
        }
    }

    /// Directory frames with their files laid inside as cells, area by lines.
    internal static func treemap(_ root: DirectoryNode, size: CGSize) -> Treemap {
        var frames: [TreemapFrame] = []
        var cells: [TreemapCell] = []
        func layout(_ node: DirectoryNode, in rect: CGRect, depth: Int) {
            let inner: CGRect
            if depth == 0 {
                inner = rect
            } else {
                frames.append(TreemapFrame(path: node.path, label: node.name, depth: depth, rect: rect))
                inner = CGRect(
                    x: rect.minX + Metrics.treemapPadding,
                    y: rect.minY + Metrics.treemapHeader,
                    width: rect.width - 2 * Metrics.treemapPadding,
                    height: rect.height - Metrics.treemapHeader - Metrics.treemapPadding
                )
            }
            guard inner.width > 0, inner.height > 0 else { return }
            enum Item {
                case directory(DirectoryNode)
                case file(ArchitectureExtractedFile)
            }
            let items: [(weight: Double, item: Item)] = (
                node.directories.map { (Double($0.lines), Item.directory($0)) }
                    + node.files.map { (Double($0.lineCount), Item.file($0)) }
            ).filter { $0.0 > 0 }.sorted { $0.0 > $1.0 }
            let rects = squarify(weights: items.map(\.weight), in: inner)
            for (entry, cellRect) in zip(items, rects) {
                switch entry.item {
                case .directory(let child):
                    layout(child, in: cellRect, depth: depth + 1)
                case .file(let file):
                    cells.append(TreemapCell(file: file, rect: cellRect))
                }
            }
        }
        layout(root, in: CGRect(origin: .zero, size: size), depth: 0)
        return Treemap(frames: frames, cells: cells)
    }

    // MARK: Tables

    internal struct ConstructRow: Hashable, Identifiable {
        internal let kind: String
        internal let count: ArchitectureExtractionCount

        internal var id: String { kind }
    }

    /// Declared against mapped per declaration kind, most declared first.
    internal static func constructRows(_ summary: ArchitectureExtractionSummary) -> [ConstructRow] {
        summary.byKind
            .map { ConstructRow(kind: $0.key, count: $0.value) }
            .sorted { left, right in
                left.count.total != right.count.total ? left.count.total > right.count.total : left.kind < right.kind
            }
    }

    /// Mechanical passes first, most citations first, then semantic ones.
    internal static func passRows(_ document: ArchitectureExtractionDocument) -> [ArchitectureExtractionPass] {
        document.passes.sorted { left, right in
            if left.isMechanical != right.isMechanical { return left.isMechanical }
            if left.citations != right.citations { return left.citations > right.citations }
            return left.id < right.id
        }
    }

    internal struct UntouchedGroup: Hashable, Identifiable {
        internal let directory: String
        internal let files: [ArchitectureExtractedFile]

        internal var id: String { directory }
    }

    /// Files no mechanical pass cited, grouped by directory, filtered by the query.
    internal static func untouchedGroups(
        _ document: ArchitectureExtractionDocument,
        query: String,
        origins: [String: [EntityOrigin]]
    ) -> [UntouchedGroup] {
        var groups: [String: [ArchitectureExtractedFile]] = [:]
        for file in document.files where !file.touched && fileMatches(file, query: query, origins: origins) {
            groups[file.directory, default: []].append(file)
        }
        return groups.keys.sorted().map { directory in
            UntouchedGroup(directory: directory, files: (groups[directory] ?? []).sorted { $0.path < $1.path })
        }
    }

    // MARK: Stats

    internal struct Stat: Hashable, Identifiable {
        internal let value: String
        internal let label: String

        internal var id: String { label }
    }

    internal static func stats(_ summary: ArchitectureExtractionSummary) -> [Stat] {
        [
            Stat(value: "\(summary.touchedFiles)/\(summary.files)", label: "Files touched"),
            Stat(value: "\(summary.types.mapped)/\(summary.types.total)", label: "Types mapped"),
            Stat(value: "\(summary.functions.mapped)/\(summary.functions.total)", label: "Functions mapped"),
            Stat(value: "\(summary.entitiesWithOrigin)/\(summary.entities)", label: "Entities wired"),
            Stat(value: "\(summary.passes)", label: "Passes"),
        ]
    }
}
