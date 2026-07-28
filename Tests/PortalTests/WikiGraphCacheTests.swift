import Testing
import Foundation
@testable import Portal

@Suite("Wiki Graph Disk Cache")
struct WikiGraphCacheTests {

    private func page(_ id: String) -> WikiPage {
        WikiPage(
            id: id, title: id.capitalized, type: "concept", tags: [],
            path: "concepts/\(id).md", created: nil, updated: nil, confidence: nil,
            contested: false, tagPath: [], integrationLinks: []
        )
    }

    private func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-cache-test-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test("Round-trips a graph through disk")
    func roundTrip() async throws {
        let cache = WikiGraphCache(directory: scratchDir())
        let graph = WikiGraph(
            pages: [page("alpha"), page("beta")],
            links: [WikiLink(source: "alpha", target: "beta", type: "wikilink")]
        )
        cache.store(graph, identity: "gw-a", wiki: "main")
        // store() is fire-and-forget on a background task; poll until it lands.
        var loaded: WikiGraph?
        for _ in 0..<50 {
            loaded = await cache.load(identity: "gw-a", wiki: "main")
            if loaded != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loaded?.pages.count == 2)
        #expect(loaded?.links.count == 1)
        #expect(loaded?.pages.contains { $0.id == "alpha" } == true)
    }

    @Test("Missing key returns nil, never throws")
    func missingKey() async {
        let cache = WikiGraphCache(directory: scratchDir())
        let loaded = await cache.load(identity: "never-written", wiki: nil)
        #expect(loaded == nil)
    }

    @Test("Distinct identity or wiki maps to distinct entries")
    func keyIsolation() {
        let a = WikiGraphCache.slug(identity: "gw-a", wiki: "main")
        let b = WikiGraphCache.slug(identity: "gw-b", wiki: "main")
        let c = WikiGraphCache.slug(identity: "gw-a", wiki: "other")
        let dDefault = WikiGraphCache.slug(identity: "gw-a", wiki: nil)
        #expect(a != b)
        #expect(a != c)
        #expect(a != dDefault)
    }

    @Test("Slug is stable across calls (survives restart)")
    func slugStable() {
        #expect(
            WikiGraphCache.slug(identity: "gw-a", wiki: "main")
            == WikiGraphCache.slug(identity: "gw-a", wiki: "main")
        )
    }

    @Test("Stored graph is overwritten by a later store to the same key")
    func overwrite() async throws {
        let cache = WikiGraphCache(directory: scratchDir())
        cache.store(WikiGraph(pages: [page("old")], links: []), identity: "gw", wiki: nil)
        // Let the first write settle.
        for _ in 0..<50 {
            if await cache.load(identity: "gw", wiki: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        cache.store(WikiGraph(pages: [page("new1"), page("new2")], links: []), identity: "gw", wiki: nil)
        var loaded: WikiGraph?
        for _ in 0..<50 {
            loaded = await cache.load(identity: "gw", wiki: nil)
            if loaded?.pages.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loaded?.pages.count == 2)
        #expect(loaded?.pages.contains { $0.id == "new1" } == true)
    }
}
