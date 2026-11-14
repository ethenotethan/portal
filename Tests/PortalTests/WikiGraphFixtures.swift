import Foundation
import CoreGraphics
@testable import Portal

/// Deterministic wiki fixtures shaped like the 5,055-page / 15,480-link wiki
/// the graph was profiled on: a handful of hubs with degree in the thousands
/// (7 hubs carried 10,385 of its links), a median degree of 1, two flat page
/// types (`milestone-event` ≈ 59 %, `org` ≈ 40 %), every page one folder deep,
/// ~37-character titles. Seeded, so the same call yields the same graph on any
/// machine — the perf harness depends on that.
internal enum WikiGraphFixtures {

    /// SplitMix64 — small, seedable, and identical everywhere.
    internal struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        internal init(seed: UInt64) { state = seed }
        internal mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    internal static func page(_ index: Int, type: String, folder: String) -> WikiPage {
        let slug = "page-\(index)"
        return WikiPage(
            id: slug, title: "Fixture page \(index) — a deterministic title", type: type, tags: [],
            path: "\(folder)/\(slug).md", created: nil, updated: nil, confidence: nil,
            contested: false, tagPath: [], integrationLinks: []
        )
    }

    /// `nodes` pages and exactly `links` links (or fewer if the graph can't
    /// hold that many distinct pairs): every non-hub page links to one hub,
    /// then random extra pairs fill the rest.
    internal static func graph(nodes: Int, links linkCount: Int, seed: UInt64 = 0x5EED) -> WikiGraph {
        var rng = SeededGenerator(seed: seed)
        let hubCount = max(1, nodes / 700)
        var pages: [WikiPage] = []
        pages.reserveCapacity(nodes)
        for index in 0..<nodes {
            let isHub = index < hubCount
            let type = isHub ? "org" : (index.isMultiple(of: 5) ? "org" : "milestone-event")
            let folder = isHub ? "entities/org" : (type == "org" ? "entities/org" : "events/milestone")
            pages.append(page(index, type: type, folder: folder))
        }
        var seen = Set<UInt64>()
        var links: [WikiLink] = []
        func add(_ a: Int, _ b: Int) {
            guard a != b else { return }
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            guard seen.insert(key).inserted else { return }
            links.append(WikiLink(source: pages[a].id, target: pages[b].id, type: "wikilink"))
        }
        for index in hubCount..<nodes where links.count < linkCount {
            // Skewed hub choice: the first hubs are the biggest, like the real wiki.
            let hub = Int(Double(hubCount) * pow(Double.random(in: 0..<1, using: &rng), 1.6))
            add(index, min(hub, hubCount - 1))
        }
        var attempts = 0
        while links.count < linkCount && attempts < linkCount * 20 {
            attempts += 1
            add(Int.random(in: 0..<nodes, using: &rng), Int.random(in: 0..<nodes, using: &rng))
        }
        return WikiGraph(pages: pages, links: links)
    }

    /// Deterministic, roughly uniform positions: a golden-angle spiral with
    /// the given spacing, centred on the canvas.
    internal static func spiralPositions(count: Int, spacing: CGFloat, canvas: CGSize) -> [CGPoint] {
        (0..<count).map { index in
            let radius = spacing * CGFloat(index).squareRoot()
            let angle = CGFloat(index) * 2.399_963
            return CGPoint(x: canvas.width / 2 + cos(angle) * radius, y: canvas.height / 2 + sin(angle) * radius)
        }
    }

    /// Seeded random points in a box.
    internal static func randomPoints(count: Int, in rect: CGRect, seed: UInt64) -> [CGPoint] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            CGPoint(
                x: CGFloat.random(in: rect.minX...rect.maxX, using: &rng),
                y: CGFloat.random(in: rect.minY...rect.maxY, using: &rng)
            )
        }
    }

    /// Index-aligned links for a graph over the view model's node order.
    internal static func indexedLinks(_ graph: WikiGraph) -> [(sourceIndex: Int, targetIndex: Int)] {
        let byID = Dictionary(uniqueKeysWithValues: graph.pages.enumerated().map { ($1.id, $0) })
        return graph.links.compactMap { link in
            guard let s = byID[link.source], let t = byID[link.target] else { return nil }
            return (s, t)
        }
    }
}
