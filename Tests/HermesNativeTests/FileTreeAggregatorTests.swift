import Testing
import Foundation
@testable import HermesNative

/// The "where" lens aggregation: confident path extraction + folding touched
/// files into a directory tree with heat + cross-highlight node ids.
@Suite("File tree aggregator")
internal struct FileTreeAggregatorTests {

    private func toolNode(_ id: String, name: String, context: String) -> ThoughtGraphNode {
        ThoughtGraphNode(id: id, name: name, context: context, isComplete: true, startedAt: Date())
    }

    // MARK: - confidentFilePath

    @Test("extracts a real path from a read/write tool context")
    internal func extractsPath() {
        let n = toolNode("t1", name: "read_file", context: "Reading Sources/Gateway/Client.swift")
        #expect(n.confidentFilePath == "Sources/Gateway/Client.swift")
    }

    @Test("does not extract from non-file tools")
    internal func skipsNonFileTools() {
        let n = toolNode("t1", name: "web_search", context: "searching for auth flow")
        #expect(n.confidentFilePath == nil)
    }

    @Test("rejects version-string false positives")
    internal func rejectsVersions() {
        let n = toolNode("t1", name: "read_file", context: "using v2.3")
        // "v2.3" has no slash and is <5 chars after the dot rule — not a path.
        #expect(n.confidentFilePath == nil)
    }

    // MARK: - tree building

    @Test("folds touched files into a directory hierarchy")
    internal func buildsHierarchy() {
        let nodes = [
            toolNode("t1", name: "read_file", context: "Reading Sources/Gateway/Client.swift"),
            toolNode("t2", name: "read_file", context: "Reading Sources/Gateway/Event.swift"),
            toolNode("t3", name: "write_file", context: "Writing Views/Chat.swift"),
        ]
        let roots = FileTreeAggregator.build(from: nodes)
        // Two top-level dirs: Sources, Views (dirs sorted first, alphabetical).
        #expect(roots.count == 2)
        #expect(roots.allSatisfy { $0.isDirectory })
        let sources = roots.first { $0.name == "Sources" }
        let gateway = sources?.children.first { $0.name == "Gateway" }
        #expect(gateway?.children.count == 2)   // Client.swift + Event.swift
    }

    @Test("write action beats read for a file's heat")
    internal func heatPrecedence() {
        let nodes = [
            toolNode("t1", name: "read_file", context: "Reading a/File.swift"),
            toolNode("t2", name: "patch", context: "Editing a/File.swift"),
        ]
        let roots = FileTreeAggregator.build(from: nodes)
        let file = roots.first?.children.first
        #expect(file?.dominantAction == .patch)
        #expect(file?.touchCount == 2)
        // Both touches recorded for cross-highlighting.
        #expect(file?.touchingNodeIDs.contains("t1") == true)
        #expect(file?.touchingNodeIDs.contains("t2") == true)
    }

    @Test("nodes with no recognizable path produce an empty tree")
    internal func emptyWhenNoPaths() {
        let nodes = [toolNode("t1", name: "web_search", context: "just prose")]
        #expect(FileTreeAggregator.build(from: nodes).isEmpty)
    }
}
