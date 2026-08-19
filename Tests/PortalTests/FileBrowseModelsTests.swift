import Testing
import Foundation
@testable import Portal

// Decoders for the read-only file browser's wire models. The gateway sends
// snake_case dicts (`has_children`, `root_path`, `read_only`); these tests pin
// the field mapping, the file/dir branching, and the display-derived flags so a
// server rename can't silently blank the browser.
@Suite("File browse models")
internal struct FileBrowseModelsTests {

    private func entryDict(_ pairs: [String: Any]) -> [String: AnyCodable] {
        pairs.mapValues { AnyCodable(any: $0) }
    }

    @Test("A file entry decodes size and reports no children")
    internal func fileEntryDecodes() {
        let entry = FileEntry.from(
            entryDict(["name": "x402_snapshot.py", "path": "indexing/x402_snapshot.py", "type": "file", "size": 2048, "has_children": true]),
            root: "repo"
        )
        #expect(entry != nil)
        #expect(entry?.isDirectory == false)
        #expect(entry?.size == 2048)
        // has_children is a directory concern; a file never advertises children.
        #expect(entry?.hasChildren == false)
        #expect(entry?.id == "repo:indexing/x402_snapshot.py")
    }

    @Test("A directory entry carries has_children and zero size default")
    internal func dirEntryDecodes() {
        let entry = FileEntry.from(
            entryDict(["name": "indexing", "path": "indexing", "type": "dir", "has_children": true]),
            root: "hermes"
        )
        #expect(entry?.isDirectory == true)
        #expect(entry?.hasChildren == true)
        #expect(entry?.size == 0)
    }

    @Test("A directory with no has_children flag defaults to false")
    internal func dirWithoutChildrenFlag() {
        let entry = FileEntry.from(
            entryDict(["name": "empty", "path": "empty", "type": "dir"]),
            root: "repo"
        )
        #expect(entry?.hasChildren == false)
    }

    @Test("An entry missing a required field is dropped")
    internal func malformedEntryDropped() {
        #expect(FileEntry.from(entryDict(["path": "a", "type": "file"]), root: "repo") == nil)
        #expect(FileEntry.from(entryDict(["name": "a", "type": "file"]), root: "repo") == nil)
        #expect(FileEntry.from(entryDict(["name": "a", "path": "a"]), root: "repo") == nil)
    }

    @Test("A listing decodes children and skips malformed rows")
    internal func listingDecodes() {
        let dict = entryDict([
            "root": "repo",
            "root_path": "/Users/x/.hermes/hermes-agent",
            "path": "indexing",
            "entries": [
                ["name": "a.py", "path": "indexing/a.py", "type": "file", "size": 10],
                ["name": "sub", "path": "indexing/sub", "type": "dir", "has_children": true],
                ["type": "file"], // malformed — dropped
            ],
        ])
        let listing = FileListing.from(dict, requestedRoot: "repo")
        #expect(listing.root == "repo")
        #expect(listing.rootPath == "/Users/x/.hermes/hermes-agent")
        #expect(listing.path == "indexing")
        #expect(listing.entries.count == 2)
        // Children inherit the listing's resolved root, not just the request.
        #expect(listing.entries.allSatisfy { $0.root == "repo" })
    }

    @Test("A listing falls back to the requested root when the server omits it")
    internal func listingRootFallback() {
        let listing = FileListing.from(entryDict(["entries": []]), requestedRoot: "hermes")
        #expect(listing.root == "hermes")
        #expect(listing.rootPath.isEmpty)
        #expect(listing.entries.isEmpty)
    }

    @Test("File content decodes and defaults read-only to true")
    internal func fileContentDecodes() {
        let content = FileContent.from(
            entryDict(["root": "repo", "path": "README.md", "content": "# Hi", "size": 4, "read_only": false, "language": "md"]),
            requestedRoot: "repo", requestedPath: "README.md"
        )
        #expect(content.content == "# Hi")
        #expect(content.size == 4)
        #expect(content.readOnly == false)
        #expect(content.isMarkdown == true)
        #expect(content.fileName == "README.md")
    }

    @Test("Missing read_only defaults to read-only, and non-markdown reads as code")
    internal func fileContentDefaults() {
        let content = FileContent.from(
            entryDict(["content": "print(1)", "language": "py"]),
            requestedRoot: "repo", requestedPath: "indexing/x402_snapshot.py"
        )
        #expect(content.readOnly == true) // safe default when the server is silent
        #expect(content.isMarkdown == false)
        #expect(content.fileName == "x402_snapshot.py") // falls back to requested path
        #expect(content.root == "repo")
    }
}
