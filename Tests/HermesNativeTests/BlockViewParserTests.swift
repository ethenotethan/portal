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
