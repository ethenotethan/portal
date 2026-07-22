import Testing
import Foundation
@testable import HermesNative

@Suite("Diff Line Parser")
struct DiffLineParserTests {

    @Test("Classifies unified diff lines; file markers beat +/- prefixes")
    func classifiesLines() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        index 1234567..89abcde 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,4 @@
         let unchanged = 1
        -let removed = 2
        +let added = 2
        +let alsoAdded = 3
        """
        let lines = DiffLine.parse(diff)
        #expect(lines.map(\.kind) == [
            .fileHeader, .fileHeader, .fileHeader, .fileHeader,
            .hunk, .context, .deletion, .addition, .addition,
        ])
        #expect(lines.filter { $0.kind == .addition }.count == 2)
        #expect(lines.filter { $0.kind == .deletion }.count == 1)
    }

    @Test("Bare -/+ diffs without git headers still classify")
    func bareDiff() {
        let lines = DiffLine.parse("-old\n+new\n context")
        #expect(lines.map(\.kind) == [.deletion, .addition, .context])
    }
}

@Suite("File Tree Parser")
struct FileTreeParserTests {

    @Test("Parses box-drawing trees with correct depths")
    func boxDrawing() {
        let tree = """
        hermes-native/
        ├── Sources/
        │   ├── main.swift
        │   └── Views/
        │       └── ChatView.swift
        └── README.md
        """
        let nodes = FileTreeNode.parse(tree)
        #expect(nodes.map(\.name) == ["hermes-native", "Sources", "main.swift", "Views", "ChatView.swift", "README.md"])
        #expect(nodes.map(\.depth) == [0, 1, 2, 2, 3, 1])
        #expect(nodes[0].isDirectory)
        #expect(nodes[1].isDirectory)
        #expect(!nodes[2].isDirectory)
    }

    @Test("Directory inferred from deeper children even without trailing slash")
    func inferredDirectory() {
        let nodes = FileTreeNode.parse("""
        src
        ├── lib
        │   └── util.py
        └── app.py
        """)
        #expect(nodes[0].isDirectory)  // src has deeper children
        #expect(nodes[1].isDirectory)  // lib has deeper children
        #expect(!nodes[2].isDirectory) // util.py leaf
    }

    @Test("Plain-indent trees and trailing annotations parse")
    func indentAndAnnotations() {
        let nodes = FileTreeNode.parse("""
        project/
          src/
            main.rs  # entry point
          Cargo.toml
        """)
        #expect(nodes.map(\.depth) == [0, 1, 2, 1])
        #expect(nodes[2].name == "main.rs")
        #expect(nodes[2].annotation == "entry point")
    }

    @Test("ASCII connector variants parse")
    func asciiConnectors() {
        let nodes = FileTreeNode.parse("""
        root/
        |-- a.txt
        `-- b.txt
        """)
        #expect(nodes.map(\.name) == ["root", "a.txt", "b.txt"])
        #expect(nodes.map(\.depth) == [0, 1, 1])
    }
}

@Suite("Fence Language Routing")
struct FenceLanguageRoutingTests {

    @Test("diff/patch and tree fences route to their views")
    func routing() {
        #expect(MarkdownParser.isDiffLanguage("diff"))
        #expect(MarkdownParser.isDiffLanguage("patch"))
        #expect(MarkdownParser.isDiffLanguage(" Diff "))
        #expect(!MarkdownParser.isDiffLanguage("swift"))
        #expect(MarkdownParser.isTreeLanguage("tree"))
        #expect(!MarkdownParser.isTreeLanguage("treemap"))  // mermaid type
    }
}

@Suite("Inline Math")
struct InlineMathTests {

    @Test("Simple variables and expressions convert to Unicode")
    func simpleSpans() {
        #expect(InlineMath.render("coefficient of $x$, square it") == "coefficient of 𝑥, square it")
        #expect(InlineMath.render("$b^2 - 4ac$") == "𝑏² − 4𝑎𝑐")
        #expect(InlineMath.render("$x_1$ and $x_2$") == "𝑥₁ and 𝑥₂")
        #expect(InlineMath.render("$\\pi r^2$") == "π 𝑟²")   // source spacing preserved
        #expect(InlineMath.render("$\\alpha + \\beta$") == "α + β")
    }

    @Test("Currency and unconvertible TeX pass through untouched")
    func passthrough() {
        #expect(InlineMath.render("costs $5 and $10 total") == "costs $5 and $10 total")
        #expect(InlineMath.render("$\\frac{a}{b}$") == "$\\frac{a}{b}$")
        #expect(InlineMath.render("no math here") == "no math here")
        // Display math untouched — MathView owns it.
        #expect(InlineMath.render("$$x^2$$") == "$$x^2$$")
    }

    @Test("Unclosed dollar and mixed content stay safe")
    func edgeCases() {
        // Unclosed $ passes through.
        #expect(InlineMath.render("price is $99") == "price is $99")
        // First span converts; what remains has one unpaired $ and stays raw.
        #expect(InlineMath.render("$x$ costs $5") == "𝑥 costs $5")
    }
}

@Suite("Stat Tiles")
struct StatTileSpecTests {

    @Test("Parses tiles with all fields and defaults")
    func fullTile() {
        let spec = StatTileSpec.parse("""
        {"tiles": [
          {"label": "Requests", "value": 128400, "unit": "/day",
           "delta": 12.5, "deltaLabel": "vs last week", "trend": [98, 121, 128]},
          {"label": "Uptime", "value": "99.97%"}
        ]}
        """)
        #expect(spec?.tiles.count == 2)
        #expect(spec?.tiles[0].delta == 12.5)
        #expect(spec?.tiles[0].upIsGood == true)  // default
        #expect(spec?.tiles[1].value.display == "99.97%")
        #expect(spec?.tiles[1].trend == nil)
    }

    @Test("Numeric values auto-compact")
    func compactFormatting() {
        #expect(StatTileSpec.TileValue.number(128_400).display == "128.4K")
        #expect(StatTileSpec.TileValue.number(4_200_000).display == "4.2M")
        #expect(StatTileSpec.TileValue.number(2_100_000_000).display == "2.1B")
        #expect(StatTileSpec.TileValue.number(1_284).display == "1,284")   // under 10K stays exact
        #expect(StatTileSpec.TileValue.number(42.5).display == "42.5")
        #expect(StatTileSpec.TileValue.number(7).display == "7")
    }

    @Test("Empty or malformed specs return nil")
    func malformed() {
        #expect(StatTileSpec.parse("{\"tiles\": []}") == nil)
        #expect(StatTileSpec.parse("not json") == nil)
        #expect(StatTileSpec.parse("{\"tiles\": [{\"label\": \"x\"}]}") == nil)  // missing value
    }
}

@Suite("Network Graph Spec")
struct NetworkGraphSpecTests {

    @Test("Parses nodes/edges; label defaults to id; size clamps")
    func parsesSpec() {
        let spec = NetworkGraphSpec.parse("""
        {"title": "Services", "nodes": [
           {"id": "api", "label": "API", "group": "backend", "size": 9},
           {"id": "db", "group": "data", "size": 0.1},
           {"id": "cache"}
         ],
         "edges": [{"from": "api", "to": "db", "label": "reads"},
                   {"from": "api", "to": "cache"}]}
        """)
        #expect(spec?.nodes.count == 3)
        #expect(spec?.nodes[1].label == "db")            // defaults to id
        #expect(spec?.nodes[0].size == 3)                // clamped from 9
        #expect(spec?.nodes[1].size == 0.5)              // clamped from 0.1
        #expect(spec?.directed == true)                  // default
        #expect(spec?.groups == ["backend", "data"])     // nil group excluded
        #expect(spec?.edges.count == 2)
    }

    @Test("Duplicate nodes dedupe; dangling edges drop instead of failing")
    func sanitizes() {
        let spec = NetworkGraphSpec.parse("""
        {"nodes": [{"id": "a"}, {"id": "a"}, {"id": "b"}],
         "edges": [{"from": "a", "to": "b"}, {"from": "a", "to": "ghost"}]}
        """)
        #expect(spec?.nodes.count == 2)
        #expect(spec?.edges.count == 1)
    }

    @Test("Empty nodes or malformed JSON return nil")
    func malformed() {
        #expect(NetworkGraphSpec.parse("{\"nodes\": []}") == nil)
        #expect(NetworkGraphSpec.parse("graph TD\nA-->B") == nil)
    }

    @Test("Layout is deterministic and places all nodes within bounds")
    func layoutDeterministic() {
        let spec = NetworkGraphSpec.parse("""
        {"nodes": [{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "d"}],
         "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "c"},
                   {"from": "c", "to": "d"}, {"from": "d", "to": "a"}]}
        """)!
        let first = NetworkGraphLayout.layout(spec, width: 600)
        let second = NetworkGraphLayout.layout(spec, width: 600)
        #expect(first.placed.count == 4)
        for (a, b) in zip(first.placed, second.placed) {
            #expect(a.position == b.position)   // seeded start → same result
        }
        for placed in first.placed {
            #expect(placed.position.x >= 0 && placed.position.x <= 600)
            #expect(placed.position.y >= 0 && placed.position.y <= first.size.height)
        }
        // Connected square should not collapse to a point.
        let xs = first.placed.map(\.position.x)
        #expect((xs.max()! - xs.min()!) > 50)
    }

    @Test("Mermaid syntax in a graph fence is detected for rerouting")
    func mermaidSniff() {
        #expect(NetworkGraphView.looksLikeMermaid("graph TD\n  A --> B"))
        #expect(NetworkGraphView.looksLikeMermaid("flowchart LR\n  A --> B"))
        #expect(!NetworkGraphView.looksLikeMermaid("{\"nodes\": []}"))
    }
}

@Suite("Living Artifacts")
struct LivingArtifactTests {

    @Test("Map merge unions markers by label; incoming wins conflicts")
    func mapMerge() {
        let existing = """
        {"id": "bkk", "title": "BKK Apartments", "markers": [
          {"lat": 13.72, "lon": 100.58, "label": "Ekkamai loft", "group": "shortlist", "note": "38k"},
          {"lat": 13.73, "lon": 100.56, "label": "Thonglor 2BR", "group": "viewed"}
        ]}
        """
        let incoming = """
        {"id": "bkk", "markers": [
          {"lat": 13.72, "lon": 100.58, "label": "Ekkamai loft", "group": "rejected", "note": "too loud"},
          {"lat": 13.74, "lon": 100.54, "label": "Ari studio", "group": "shortlist"}
        ]}
        """
        let merged = ArtifactMerge.merge(kind: "map", existing: existing, incoming: incoming)
        let obj = try! JSONSerialization.jsonObject(with: Data(merged.utf8)) as! [String: Any]
        let markers = obj["markers"] as! [[String: Any]]
        #expect(markers.count == 3)  // union: ekkamai (updated) + thonglor (kept) + ari (new)
        let ekkamai = markers.first { ($0["label"] as? String) == "Ekkamai loft" }!
        #expect(ekkamai["group"] as? String == "rejected")   // incoming wins
        #expect(obj["title"] as? String == "BKK Apartments") // carried over
    }

    @Test("Non-map kinds replace wholesale; malformed JSON never bricks")
    func replaceAndResilience() {
        #expect(ArtifactMerge.merge(kind: "chart", existing: "{\"a\":1}", incoming: "{\"b\":2}") == "{\"b\":2}")
        // Malformed incoming on a map: incoming passes through (no crash, no brick).
        let out = ArtifactMerge.merge(kind: "map", existing: "{\"markers\":[]}", incoming: "not json")
        #expect(out == "not json")
    }

    @Test("Store upsert merges by id and preserves titles")
    @MainActor
    func storeUpsert() {
        let store = ArtifactStore.shared
        let testID = "test-artifact-\(UUID().uuidString.prefix(8))"
        defer { store.remove(id: testID) }

        store.upsert(id: testID, kind: "map", title: "Test Map",
                     content: "{\"markers\": [{\"lat\": 1, \"lon\": 2, \"label\": \"a\"}]}")
        // Second upsert with no title must keep the original.
        let updated = store.upsert(id: testID, kind: "map", title: nil,
                     content: "{\"markers\": [{\"lat\": 3, \"lon\": 4, \"label\": \"b\"}]}")
        #expect(updated.title == "Test Map")
        let obj = try! JSONSerialization.jsonObject(with: Data(updated.content.utf8)) as! [String: Any]
        #expect((obj["markers"] as! [[String: Any]]).count == 2)  // merged, not replaced
    }

    @Test("MapSpec parses markers and groups")
    func mapSpec() {
        let spec = MapSpec.parse("""
        {"id": "bkk", "title": "BKK", "markers": [
          {"lat": 13.72, "lon": 100.58, "label": "A", "group": "shortlist"},
          {"lat": 13.73, "lon": 100.56, "label": "B", "group": "viewed", "note": "n"},
          {"lat": 13.74, "lon": 100.55, "label": "C", "group": "shortlist"}
        ]}
        """)
        #expect(spec?.markers.count == 3)
        #expect(spec?.groups == ["shortlist", "viewed"])
        #expect(spec?.id == "bkk")
        #expect(MapSpec.parse("{\"markers\": []}") == nil)  // empty → nil
    }
}

@Suite("Artifact Diff")
struct ArtifactDiffTests {

    @Test("Map diff summarizes added/removed/regrouped markers")
    func mapDiff() {
        let old = """
        {"markers": [
          {"lat": 1, "lon": 2, "label": "Ekkamai loft", "group": "shortlist", "note": "38k"},
          {"lat": 3, "lon": 4, "label": "Old place", "group": "viewed"}
        ]}
        """
        let new = """
        {"markers": [
          {"lat": 1, "lon": 2, "label": "Ekkamai loft", "group": "rejected", "note": "38k"},
          {"lat": 5, "lon": 6, "label": "Ari studio", "group": "shortlist"}
        ]}
        """
        let lines = ArtifactDiff.describe(kind: "map", old: old, new: new)!
        #expect(lines.contains("Added Ari studio"))
        #expect(lines.contains("Removed Old place"))
        #expect(lines.contains("Ekkamai loft: shortlist → rejected"))
    }

    @Test("Identical content yields no diff; non-map kinds get a size note")
    func fallbacks() {
        #expect(ArtifactDiff.describe(kind: "map", old: "{}", new: "{}") == nil)
        let lines = ArtifactDiff.describe(kind: "chart", old: "{\"a\":1}", new: "{\"a\":1,\"b\":2}")!
        #expect(lines.count == 1)
        #expect(lines[0].contains("+6 chars"))
    }

    @Test("Note-only changes are called out without group noise")
    func noteChange() {
        let old = "{\"markers\": [{\"lat\":1,\"lon\":2,\"label\":\"A\",\"group\":\"g\",\"note\":\"x\"}]}"
        let new = "{\"markers\": [{\"lat\":1,\"lon\":2,\"label\":\"A\",\"group\":\"g\",\"note\":\"y\"}]}"
        let lines = ArtifactDiff.describe(kind: "map", old: old, new: new)!
        #expect(lines == ["A: note updated"])
    }
}

@Suite("Dataset Kind")
struct DatasetKindTests {

    @Test("Spec parses rows, derives columns with key first, stringifies values")
    func specParsing() {
        let spec = DatasetSpec.parse("""
        {"key": "login", "rows": [
          {"login": "greg", "commits": 44, "active": true},
          {"login": "amy", "name": "Amy"}
        ]}
        """)!
        #expect(spec.key == "login")
        #expect(spec.columns.first == "login")           // key leads derived columns
        #expect(spec.columns.contains("commits"))
        #expect(spec.rows[0]["commits"] == "44")          // numbers stringified
        #expect(DatasetSpec.parse("{\"rows\": []}") == nil)
    }

    @Test("App-side dataset merge mirrors the gateway: union by key, incoming wins")
    func merge() {
        let old = "{\"key\": \"login\", \"rows\": [{\"login\": \"greg\", \"commits\": 41}, {\"login\": \"amy\", \"commits\": 7}]}"
        let new = "{\"rows\": [{\"login\": \"greg\", \"commits\": 44}, {\"login\": \"new\", \"commits\": 1}]}"
        let merged = ArtifactMerge.merge(kind: "dataset", existing: old, incoming: new)
        let obj = try! JSONSerialization.jsonObject(with: Data(merged.utf8)) as! [String: Any]
        let rows = (obj["rows"] as! [[String: Any]])
        #expect(rows.count == 3)
        let greg = rows.first { ($0["login"] as? String) == "greg" }!
        #expect((greg["commits"] as? Int) == 44)
        #expect(obj["key"] as? String == "login")
    }

    @Test("Dataset diff reports added/removed/changed rows by key")
    func diff() {
        let old = "{\"key\": \"login\", \"rows\": [{\"login\": \"greg\", \"commits\": 41}, {\"login\": \"gone\", \"commits\": 2}]}"
        let new = "{\"key\": \"login\", \"rows\": [{\"login\": \"greg\", \"commits\": 44}, {\"login\": \"fresh\", \"commits\": 1}]}"
        let lines = ArtifactDiff.describe(kind: "dataset", old: old, new: new)!
        #expect(lines.contains("Added fresh"))
        #expect(lines.contains("Removed gone"))
        #expect(lines.contains("greg: commits changed"))
    }
}

@Suite("Artifact Actions")
struct ArtifactActionTests {

    @Test("Actions parse; malformed entries drop without breaking the rest")
    func parsing() {
        let actions = ArtifactAction.parse([
            ["field": "status", "type": "choice", "options": ["going", "not going"]],
            ["field": "reached_out", "type": "toggle"],
            ["type": "delete"],
            ["type": "choice", "options": ["x"]],          // no field → dropped
            ["field": "f", "type": "choice"],              // no options → dropped
            ["field": "f", "type": "teleport"],            // unknown → dropped
        ] as Any)
        #expect(actions.count == 3)
        #expect(actions[0].kind == .choice && actions[0].options.count == 2)
        #expect(actions[1].kind == .toggle && actions[1].field == "reached_out")
        #expect(actions[2].kind == .delete)
        #expect(ArtifactAction.parse(nil).isEmpty)
        #expect(ArtifactAction.parse("nonsense" as Any).isEmpty)
    }

    @Test("setField updates the matching dataset row by key, case-insensitive")
    func setFieldDataset() {
        let content = """
        {"key": "name", "rows": [{"name": "Acme Conf", "status": "undecided"}, {"name": "Other", "status": "going"}]}
        """
        let out = ArtifactActionEngine.setField(
            in: content, kind: "dataset", entryKey: " acme conf ", field: "status", value: "going"
        )!
        let obj = try! JSONSerialization.jsonObject(with: out.data(using: .utf8)!) as! [String: Any]
        let rows = obj["rows"] as! [[String: Any]]
        #expect(rows[0]["status"] as? String == "going")
        #expect(rows[1]["status"] as? String == "going")   // untouched
        #expect(ArtifactActionEngine.setField(
            in: content, kind: "dataset", entryKey: "nope", field: "status", value: "x") == nil)
    }

    @Test("setField updates map markers by label")
    func setFieldMap() {
        let content = """
        {"markers": [{"lat": 1.0, "lon": 2.0, "label": "Ekkamai loft"}]}
        """
        let out = ArtifactActionEngine.setField(
            in: content, kind: "map", entryKey: "Ekkamai loft", field: "reached_out", value: true
        )!
        #expect(out.contains("\"reached_out\":true"))
    }

    @Test("markDeleted tombstones; spec parsers hide tombstoned entries")
    func tombstone() {
        let content = """
        {"key": "name", "rows": [{"name": "A"}, {"name": "B"}]}
        """
        let out = ArtifactActionEngine.markDeleted(in: content, kind: "dataset", entryKey: "A")!
        let spec = DatasetSpec.parse(out)!
        #expect(spec.rows.count == 1)
        #expect(spec.rows[0]["name"] == "B")

        let mapContent = """
        {"markers": [{"lat": 1.0, "lon": 2.0, "label": "gone", "_deleted": true},
                     {"lat": 3.0, "lon": 4.0, "label": "kept"}]}
        """
        let mapSpec = MapSpec.parse(mapContent)!
        #expect(mapSpec.markers.count == 1)
        #expect(mapSpec.markers[0].label == "kept")
    }

    @Test("Merge carries tombstones — agent re-emitting a deleted row can't resurrect it")
    func tombstoneSurvivesMerge() {
        let existing = """
        {"key": "name", "rows": [{"name": "A", "_deleted": true}, {"name": "B"}]}
        """
        let incoming = """
        {"key": "name", "rows": [{"name": "A", "note": "found again!"}, {"name": "C"}]}
        """
        let merged = ArtifactMerge.mergeDataset(existing: existing, incoming: incoming)
        let spec = DatasetSpec.parse(merged)!
        let names = spec.rows.compactMap { $0["name"] }
        #expect(!names.contains("A"))                       // still dead
        #expect(names.contains("B") && names.contains("C"))
        // Explicit un-delete wins:
        let revived = ArtifactMerge.mergeDataset(
            existing: existing,
            incoming: "{\"key\": \"name\", \"rows\": [{\"name\": \"A\", \"_deleted\": false}]}"
        )
        #expect(DatasetSpec.parse(revived)!.rows.contains { $0["name"] == "A" })
    }

    @Test("Map merge carries marker tombstones the same way")
    func mapTombstoneSurvivesMerge() {
        let existing = """
        {"markers": [{"lat": 1.0, "lon": 2.0, "label": "gone", "_deleted": true}]}
        """
        let incoming = """
        {"markers": [{"lat": 1.0, "lon": 2.0, "label": "gone", "note": "re-listed"},
                     {"lat": 5.0, "lon": 6.0, "label": "new"}]}
        """
        let merged = ArtifactMerge.mergeMap(existing: existing, incoming: incoming)
        let spec = MapSpec.parse(merged)!
        #expect(spec.markers.map(\.label) == ["new"])
    }

    @Test("Action-field values ride on map markers via extra")
    func markerExtraFields() {
        let content = """
        {"markers": [{"lat": 1.0, "lon": 2.0, "label": "loft", "reached_out": true, "score": 8}]}
        """
        let spec = MapSpec.parse(content)!
        #expect(ArtifactAction.isTruthy(spec.markers[0].extra["reached_out"]))
        #expect(spec.markers[0].extra["score"] == "8")
        #expect(spec.markers[0].extra["label"] == nil)      // typed keys excluded
    }

    @Test("isTruthy accepts bool-ish forms")
    func truthy() {
        #expect(ArtifactAction.isTruthy("true"))
        #expect(ArtifactAction.isTruthy("1"))
        #expect(!ArtifactAction.isTruthy("false"))
        #expect(!ArtifactAction.isTruthy("0"))
        #expect(!ArtifactAction.isTruthy(nil))
        #expect(!ArtifactAction.isTruthy("going"))
    }
}
