import Testing
import Foundation
@testable import Portal

@Suite("Architecture extraction layout — provenance wiring, treemap and tables")
internal struct ArchitectureExtractionLayoutTests {
    private typealias Layout = ArchitectureExtractionLayout

    private func fixture() throws -> ArchitectureExtractionDocument {
        try ArchitectureExtractionDocumentTests.fixtureDocument()
    }

    // MARK: Tree

    @Test("folds single-child chains and orders by lines, then name")
    internal func treeFolding() throws {
        let document = try fixture()
        let root = Layout.tree(files: document.files)
        #expect(root.name.isEmpty)
        #expect(root.path.isEmpty)
        #expect(root.depth == 0)
        #expect(root.lines == 490)
        #expect(root.files.isEmpty)
        // Sources/App is one folded shell (largest first), App/ the other.
        #expect(root.directories.map(\.name) == ["Sources/App", "App"])
        let sources = root.directories[0]
        #expect(sources.path == "Sources/App")
        #expect(sources.depth == 1)
        #expect(sources.directories.map(\.name) == ["Views", "Models"], "Views has 300 lines, Models 160")
        let models = sources.directories[1]
        #expect(models.path == "Sources/App/Models")
        #expect(models.depth == 2)
        #expect(models.files.map(\.fileName) == ["ActivityStore.swift", "ActivityItem.swift"], "largest file first")
        #expect(models.lines == 160)
        let app = root.directories[1]
        #expect(app.path == "App")
        #expect(app.files.map(\.path) == ["App/IOSApp.swift"])
        #expect(root.allFiles.count == 4)
        #expect(root.allDirectories.map(\.path) == ["", "Sources/App", "Sources/App/Views", "Sources/App/Models", "App"])
        #expect(Layout.defaultOpenDirectories(root) == ["", "Sources/App", "App"], "the root and its first level start open")
        #expect(Layout.tree(files: []).allFiles.isEmpty)
    }

    // MARK: Provenance index

    @Test("indexes origins by file, sorted by line then label")
    internal func originsByFile() throws {
        let document = try fixture()
        let origins = Layout.originsByFile(document)
        let store = try #require(origins["Sources/App/Models/ActivityStore.swift"])
        #expect(store.map(\.origin.line) == [7, 20, 20])
        #expect(store.map(\.label) == ["ActivityStore", "ActivityStore", "portal.activityItems"])
        #expect(store[0].entityID == "store:domain-models:ActivityStore")
        #expect(store[0].kind == "store")
        #expect(origins["Sources/App/Models/ActivityItem.swift"] == nil)
        #expect(origins["Sources/App/Views/ChatView.swift"]?.count == 3)
    }

    @Test("kinds appear in contract order with unknown kinds after, and carry labels")
    internal func kinds() throws {
        let document = try fixture()
        #expect(Layout.kinds(in: document) == ["caller", "provider", "store", "artifact", "widget"])
        #expect(Layout.kindLabel("store") == "Data stores")
        #expect(Layout.kindLabel("widget") == "widget")
        #expect(Layout.kindOrder.first == "endpoint")
    }

    // MARK: Search

    @Test("files match on path, declaration, pass, entity label or rule; entities on label, kind, rule or path")
    internal func searchMatching() throws {
        let document = try fixture()
        let origins = Layout.originsByFile(document)
        let store = try #require(document.fileByPath["Sources/App/Models/ActivityStore.swift"])
        #expect(Layout.fileMatches(store, query: "", origins: origins))
        #expect(Layout.fileMatches(store, query: "  ", origins: origins))
        #expect(Layout.fileMatches(store, query: "activitystore", origins: origins))
        #expect(Layout.fileMatches(store, query: "helper", origins: origins), "a declaration name")
        #expect(Layout.fileMatches(store, query: "defaults_key", origins: origins), "a pass")
        #expect(Layout.fileMatches(store, query: "portal.activityItems", origins: origins), "an entity it produced")
        #expect(!Layout.fileMatches(store, query: "ChatView", origins: origins))
        let item = try #require(document.fileByPath["Sources/App/Models/ActivityItem.swift"])
        #expect(Layout.fileMatches(item, query: "Kind", origins: origins), "untouched files still match on declarations")
        let caller = try #require(document.entityByID["caller:chat-state:ChatViewModel"])
        #expect(Layout.entityMatches(caller, query: "chatview"))
        #expect(Layout.entityMatches(caller, query: "CALLER"))
        #expect(Layout.entityMatches(caller, query: "surface_call"))
        #expect(Layout.entityMatches(caller, query: "Views/ChatView"))
        #expect(!Layout.entityMatches(caller, query: "store"))
        #expect(Layout.entityMatches(caller, query: ""))
    }

    // MARK: Rows

    @Test("rows follow the open sets: closed shells bundle their files, open kinds list their entities")
    internal func rows() throws {
        let document = try fixture()
        let root = Layout.tree(files: document.files)
        let origins = Layout.originsByFile(document)
        let closed = Layout.rows(document: document, tree: root, openDirectories: [], openKinds: [], query: "", origins: origins)
        #expect(closed.left.count == 1)
        #expect(closed.left[0].kind == .directory)
        #expect(closed.left[0].label == "repository")
        #expect(!closed.left[0].isOpen)
        #expect(closed.left[0].filePaths.count == 4)
        #expect(closed.left[0].wiredFiles == 3)
        #expect(closed.left[0].originCount == 7)
        #expect(closed.left[0].declarationCount == 7)
        #expect(closed.left[0].matches)
        #expect(closed.right.map(\.key) == ["caller", "provider", "store", "artifact", "widget"])
        #expect(closed.right.allSatisfy { $0.kind == .entityKind && !$0.isOpen })
        #expect(closed.right[0].entityIDs == ["caller:chat-state:ChatViewModel"])
        #expect(closed.right[0].originCount == 2)
        #expect(closed.count == 5)

        let open = Layout.rows(
            document: document, tree: root, openDirectories: Layout.defaultOpenDirectories(root), openKinds: ["store"], query: "", origins: origins
        )
        #expect(open.left.map(\.key) == ["", "Sources/App", "Sources/App/Views", "Sources/App/Models", "App", "App/IOSApp.swift"])
        #expect(open.left.map(\.depth) == [0, 1, 2, 2, 1, 2])
        let views = open.left[2]
        #expect(views.kind == .directory && !views.isOpen && views.wiredFiles == 1 && views.filePaths == ["Sources/App/Views/ChatView.swift"])
        let ios = open.left[5]
        #expect(ios.kind == .file && ios.label == "IOSApp.swift" && ios.originCount == 1 && !ios.isUntouchedFile)
        #expect(open.right.map(\.key) == ["caller", "provider", "store", "store:domain-models:ActivityStore", "artifact", "widget"])
        #expect(open.right[3].kind == .entity && open.right[3].originCount == 2 && open.right[3].label == "ActivityStore")

        let everything = Layout.rows(
            document: document, tree: root, openDirectories: Set(root.allDirectories.map(\.path)), openKinds: [], query: "Kind", origins: origins
        )
        let item = try #require(everything.left.first { $0.key == "Sources/App/Models/ActivityItem.swift" })
        #expect(item.isUntouchedFile)
        #expect(item.declarationCount == 2)
        #expect(item.matches, "matches the query on a declaration")
        let chat = try #require(everything.left.first { $0.key == "Sources/App/Views/ChatView.swift" })
        #expect(!chat.matches)
        let app = try #require(everything.left.first { $0.key == "App" })
        #expect(!app.matches, "a directory matches when any file beneath does")
        #expect(everything.left.first { $0.key == "Sources/App/Models" }?.matches == true)
        // Files under an open directory are path-sorted.
        let modelFiles = everything.left.filter { $0.kind == .file && $0.key.hasPrefix("Sources/App/Models/") }.map(\.label)
        #expect(modelFiles == ["ActivityItem.swift", "ActivityStore.swift"])
    }

    // MARK: Wires

    @Test("wires bundle onto the visible rows and colour by a single family")
    internal func wires() throws {
        let document = try fixture()
        let root = Layout.tree(files: document.files)
        let origins = Layout.originsByFile(document)
        let closed = Layout.rows(document: document, tree: root, openDirectories: [], openKinds: [], query: "", origins: origins)
        let bundles = Layout.wires(document: document, rows: closed)
        // One left row, five right rows: one bundle per kind.
        #expect(bundles.map(\.targetRow) == [0, 1, 2, 3, 4])
        #expect(bundles.allSatisfy { $0.sourceRow == 0 })
        #expect(bundles.map(\.count) == [2, 1, 2, 1, 1])
        #expect(bundles.reduce(0) { $0 + $1.count } == 7, "every origin is one wire")
        #expect(bundles[0].family == .trigger)
        #expect(bundles[2].family == .store)
        #expect(bundles[2].filePaths == ["Sources/App/Models/ActivityStore.swift"])
        #expect(bundles[2].entityIDs == ["store:domain-models:ActivityStore"])
        #expect(bundles[4].family == .custom("novel"))
        #expect(bundles[0].width == 2, "1 + log2(2)")
        #expect(bundles[1].width == 1)

        let open = Layout.rows(
            document: document, tree: root, openDirectories: Set(root.allDirectories.map(\.path)), openKinds: ["store", "artifact"], query: "", origins: origins
        )
        let detailed = Layout.wires(document: document, rows: open)
        let storeRow = try #require(open.left.firstIndex { $0.key == "Sources/App/Models/ActivityStore.swift" })
        let storeEntity = try #require(open.right.firstIndex { $0.key == "store:domain-models:ActivityStore" })
        let artifactEntity = try #require(open.right.firstIndex { $0.key == "artifact:user-defaults:portal.activityItems" })
        #expect(detailed.contains { $0.sourceRow == storeRow && $0.targetRow == storeEntity && $0.count == 2 })
        #expect(detailed.contains { $0.sourceRow == storeRow && $0.targetRow == artifactEntity && $0.count == 1 })
        #expect(detailed == detailed.sorted { $0.sourceRow != $1.sourceRow ? $0.sourceRow < $1.sourceRow : $0.targetRow < $1.targetRow })
        #expect(Layout.wires(document: document, rows: Layout.wires(document: document, rows: open).isEmpty ? open : open) == detailed, "deterministic")

        var mixed = Set<ArchitectureExtractionFamily>()
        mixed.insert(.store)
        mixed.insert(.trigger)
        let bundle = Layout.WireBundle(sourceRow: 0, targetRow: 0, count: 8, families: mixed, filePaths: [], entityIDs: [])
        #expect(bundle.family == nil, "mixed families draw quiet")
        #expect(bundle.width == 4)
    }

    // MARK: Selection

    @Test("a selection highlights the other end of its wires and dims the rest")
    internal func selection() throws {
        let document = try fixture()
        let root = Layout.tree(files: document.files)
        let origins = Layout.originsByFile(document)
        #expect(Layout.highlight(for: nil, document: document, origins: origins) == nil)
        let fileHighlight = try #require(Layout.highlight(
            for: Layout.Selection(side: .file, key: "Sources/App/Models/ActivityStore.swift"), document: document, origins: origins
        ))
        #expect(fileHighlight.files == ["Sources/App/Models/ActivityStore.swift"])
        #expect(fileHighlight.entities == ["store:domain-models:ActivityStore", "artifact:user-defaults:portal.activityItems"])
        let entityHighlight = try #require(Layout.highlight(
            for: Layout.Selection(side: .entity, key: "caller:chat-state:ChatViewModel"), document: document, origins: origins
        ))
        #expect(entityHighlight.files == ["Sources/App/Views/ChatView.swift"])
        #expect(entityHighlight.entities == ["caller:chat-state:ChatViewModel"])
        let unknown = try #require(Layout.highlight(for: Layout.Selection(side: .entity, key: "nope"), document: document, origins: origins))
        #expect(unknown.files.isEmpty && unknown.entities == ["nope"])

        let rows = Layout.rows(document: document, tree: root, openDirectories: [], openKinds: ["store"], query: "", origins: origins)
        #expect(Layout.isLinked(rows.left[0], highlight: fileHighlight), "the root holds the selected file")
        #expect(!Layout.isLinked(rows.left[0], highlight: nil))
        let storeKind = try #require(rows.right.first { $0.key == "store" })
        let storeEntity = try #require(rows.right.first { $0.key == "store:domain-models:ActivityStore" })
        let callerKind = try #require(rows.right.first { $0.key == "caller" })
        #expect(Layout.isLinked(storeKind, highlight: fileHighlight))
        #expect(Layout.isLinked(storeEntity, highlight: fileHighlight))
        #expect(!Layout.isLinked(callerKind, highlight: fileHighlight))
        #expect(!Layout.isLinked(callerKind, highlight: nil))
        let bundles = Layout.wires(document: document, rows: rows)
        let toStore = try #require(bundles.first { $0.entityIDs.contains("store:domain-models:ActivityStore") })
        let toCaller = try #require(bundles.first { $0.entityIDs.contains("caller:chat-state:ChatViewModel") })
        #expect(Layout.isSelected(toStore, highlight: fileHighlight))
        #expect(!Layout.isSelected(toCaller, highlight: fileHighlight))
        #expect(!Layout.isSelected(toStore, highlight: nil))

        #expect(!Layout.isDimmed(matches: true, query: "", isSelected: false, isLinked: false, highlight: nil))
        #expect(Layout.isDimmed(matches: false, query: "x", isSelected: false, isLinked: false, highlight: nil), "a query excludes it")
        #expect(!Layout.isDimmed(matches: false, query: "  ", isSelected: false, isLinked: false, highlight: nil), "blank query is no query")
        #expect(Layout.isDimmed(matches: true, query: "", isSelected: false, isLinked: false, highlight: fileHighlight), "not on the selection")
        #expect(!Layout.isDimmed(matches: true, query: "", isSelected: true, isLinked: false, highlight: fileHighlight))
        #expect(!Layout.isDimmed(matches: true, query: "", isSelected: false, isLinked: true, highlight: fileHighlight))
    }

    // MARK: Treemap

    @Test("squarify fills the rectangle with non-overlapping cells proportional to weight")
    internal func squarify() {
        let rect = CGRect(x: 10, y: 20, width: 400, height: 250)
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Layout.squarify(weights: weights, in: rect)
        #expect(rects.count == weights.count)
        let total = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(total - 400 * 250) < 0.01)
        let expectedShare = 6.0 / 24.0
        #expect(abs(Double(rects[0].width * rects[0].height) / (400 * 250) - expectedShare) < 1e-9)
        for (index, cell) in rects.enumerated() {
            #expect(rect.insetBy(dx: -0.001, dy: -0.001).contains(cell), "cell \(index) inside the rect")
            for other in rects[(index + 1)...] {
                let overlap = cell.intersection(other)
                #expect(overlap.isNull || overlap.width < 1e-6 || overlap.height < 1e-6, "cells do not overlap")
            }
        }
        // Squarified: the first row lies along the shorter side and the largest cell is not a sliver.
        #expect(rects[0].width / rects[0].height < 3 && rects[0].height / rects[0].width < 3)
        #expect(Layout.squarify(weights: weights, in: rect) == rects, "deterministic")
        // Zero and negative weights get empty rects; an empty rect yields empty cells.
        let sparse = Layout.squarify(weights: [0, 5, -1, 5], in: rect)
        #expect(sparse[0].size == .zero && sparse[2].size == .zero)
        #expect(abs(Double(sparse[1].width * sparse[1].height) - 400 * 250 / 2) < 0.01)
        #expect(Layout.squarify(weights: [1, 2], in: .zero).allSatisfy { $0.size == .zero })
        #expect(Layout.squarify(weights: [], in: rect).isEmpty)
        #expect(Layout.squarify(weights: [0, 0], in: rect).allSatisfy { $0.size == .zero })
    }

    @Test("the treemap nests directory frames and places every file as a cell")
    internal func treemap() throws {
        let document = try fixture()
        let root = Layout.tree(files: document.files)
        let map = Layout.treemap(root, size: CGSize(width: 1200, height: 600))
        #expect(map.frames.map(\.path) == ["Sources/App", "Sources/App/Views", "Sources/App/Models", "App"])
        #expect(map.frames.map(\.depth) == [1, 2, 2, 1])
        #expect(map.frames[0].label == "Sources/App")
        #expect(Set(map.cells.map(\.file.path)) == Set(document.files.map(\.path)))
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
        for cell in map.cells {
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(cell.rect), "\(cell.file.path)")
        }
        // Every cell sits inside its directory frame (below the header, within the padding).
        let byPath = Dictionary(map.frames.map { ($0.path, $0.rect) }, uniquingKeysWith: { first, _ in first })
        for cell in map.cells where !cell.file.directory.isEmpty {
            let frame = try #require(byPath[cell.file.directory] ?? byPath[cell.file.directory.split(separator: "/").dropLast().joined(separator: "/")])
            #expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(cell.rect), "\(cell.file.path) inside \(frame)")
        }
        let chat = try #require(map.cells.first { $0.file.fileName == "ChatView.swift" })
        let item = try #require(map.cells.first { $0.file.fileName == "ActivityItem.swift" })
        #expect(chat.rect.width * chat.rect.height > item.rect.width * item.rect.height, "area follows lines")
        #expect(map.cell(at: CGPoint(x: chat.rect.midX, y: chat.rect.midY))?.file.path == chat.file.path)
        #expect(map.cell(at: CGPoint(x: -5, y: -5)) == nil)
        #expect(Layout.treemap(root, size: CGSize(width: 1200, height: 600)) == map, "deterministic")
        #expect(Layout.treemap(root, size: CGSize(width: 40, height: 10)).cells.isEmpty || true, "a tiny canvas does not crash")
        #expect(Layout.treemap(Layout.tree(files: []), size: CGSize(width: 100, height: 100)).cells.isEmpty)
    }

    // MARK: Tables and stats

    @Test("tables report by construct and by pass, and untouched files group by directory")
    internal func tables() throws {
        let document = try fixture()
        let origins = Layout.originsByFile(document)
        let constructs = Layout.constructRows(document.summary)
        #expect(constructs.map(\.kind) == ["struct", "func", "class", "enum"], "most declared first, ties by name")
        #expect(constructs[0].count.unmapped == 1)
        #expect(constructs[3].count.share == 0)
        let passes = Layout.passRows(document)
        #expect(passes.map(\.id) == [
            "swift.store.defaults_key_literal", "swift.trigger.surface_call", "swift.store.declaration",
            "swift.trigger.launch_construction", "semantic.flow",
        ], "mechanical first, most citations first, ties by id, semantic last")
        let untouched = Layout.untouchedGroups(document, query: "", origins: origins)
        #expect(untouched.map(\.directory) == ["Sources/App/Models"])
        #expect(untouched[0].files.map(\.fileName) == ["ActivityItem.swift"])
        #expect(untouched[0].id == "Sources/App/Models")
        #expect(Layout.untouchedGroups(document, query: "ChatView", origins: origins).isEmpty)
        #expect(Layout.untouchedGroups(document, query: "Kind", origins: origins).count == 1)
        let stats = Layout.stats(document.summary)
        #expect(stats.map(\.label) == ["Files touched", "Types mapped", "Functions mapped", "Entities wired", "Passes"])
        #expect(stats.map(\.value) == ["3/4", "3/5", "1/2", "5/5", "4"])
        #expect(stats[0].id == "Files touched")
        #expect(Layout.Metrics.rowHeight > 0 && Layout.Metrics.leftColumnWidth > Layout.Metrics.indent)
    }

    @Test("the real model lays out end to end without losing a wire")
    internal func realModel() throws {
        let model = try ArchitectureExtractionDocumentTests.realModel()
        let base = try #require(model.dictionaryValue)
        let document = try #require(ArchitectureExtractionDocument.decode(base["extraction"]?.dictionaryValue))
        let root = Layout.tree(files: document.files)
        let origins = Layout.originsByFile(document)
        #expect(root.allFiles.count == document.files.count)
        let open = Layout.defaultOpenDirectories(root)
        #expect(open.contains(""))
        let rows = Layout.rows(document: document, tree: root, openDirectories: open, openKinds: [], query: "", origins: origins)
        let bundles = Layout.wires(document: document, rows: rows)
        let totalOrigins = document.entities.reduce(0) { $0 + $1.origins.count }
        #expect(bundles.reduce(0) { $0 + $1.count } == totalOrigins, "every origin lands on a visible bundle")
        #expect(bundles.allSatisfy { $0.sourceRow < rows.left.count && $0.targetRow < rows.right.count })
        let everything = Layout.rows(
            document: document, tree: root, openDirectories: Set(root.allDirectories.map(\.path)),
            openKinds: Set(Layout.kinds(in: document)), query: "", origins: origins
        )
        #expect(everything.left.filter { $0.kind == .file }.count == document.files.count)
        #expect(everything.right.filter { $0.kind == .entity }.count == document.entities.count)
        #expect(Layout.wires(document: document, rows: everything).reduce(0) { $0 + $1.count } == totalOrigins)
        let map = Layout.treemap(root, size: CGSize(width: 1200, height: 640))
        #expect(map.cells.count == document.files.filter { $0.lineCount > 0 }.count)
        #expect(Layout.untouchedGroups(document, query: "", origins: origins).reduce(0) { $0 + $1.files.count } == document.summary.untouchedFiles)
    }
}
