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
