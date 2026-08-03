import Testing
import SwiftUI
@testable import Portal

// MARK: - Fixtures

/// Definition pages as `wiki.scan` would report them, paired with the
/// frontmatter a page fetch would return. Mirrors the Hermes shape: `type:` is
/// the page type, and arbitrary keys live in frontmatter.
private enum Fixtures {

    static func page(
        id: String,
        title: String = "",
        type: String = WikiEventTypeRegistry.definitionPageType
    ) -> WikiPage {
        WikiPage(
            id: id, title: title, type: type, tags: [],
            path: "event-types/\(id).md", created: nil, updated: nil,
            confidence: nil, contested: false, tagPath: [], integrationLinks: []
        )
    }

    /// The five triggers an existing Hermes wiki would be seeded with, plus
    /// one fully-specified page and one that declares only the bare minimum.
    static let ingest = page(id: "ingest", title: "Source ingest")
    static let lint = page(id: "lint", title: "Lint fix")
    static let bare = page(id: "bare")

    static let frontmatter: [String: [String: String]] = [
        "ingest": [
            "event_kind": "ingest",
            "color": "3987e5",
            "glyph": "tray.and.arrow.down",
            "lane": "10",
            "produces_changes": "true",
        ],
        "lint": [
            "event_kind": "lint",
            "produces_changes": "false",
        ],
        // No event_kind — defines nothing.
        "bare": ["glyph": "circle"],
    ]

    static func lookup(_ page: WikiPage) -> [String: String] {
        frontmatter[page.id] ?? [:]
    }

    static func registry(_ pages: [WikiPage]) -> WikiEventTypeRegistry {
        WikiEventTypeRegistry.build(pages: pages, frontmatter: lookup)
    }
}

// MARK: - Building from pages

@Suite("Wiki Event Type Registry — building")
internal struct WikiEventTypeRegistryBuildTests {

    @Test("a fully-declared page supplies label, color, glyph, lane, and path")
    internal func declaredPageSuppliesEverything() {
        let type = Fixtures.registry([Fixtures.ingest]).resolve("ingest")
        #expect(type.isDeclared)
        #expect(type.label == "Source ingest")
        #expect(type.glyph == "tray.and.arrow.down")
        #expect(type.lane == 10)
        #expect(type.producesChanges)
        #expect(type.color == Color(hex: "3987e5"))
        // The defining page is reachable, so a chip can open the definition.
        #expect(type.pagePath == "event-types/ingest.md")
    }

    @Test("a page declaring only event_kind still resolves, with derived presentation")
    internal func partialPageFallsBackPerField() {
        let lint = Fixtures.registry([Fixtures.lint]).resolve("lint")
        #expect(lint.isDeclared)
        #expect(lint.label == "Lint fix")
        // No color/glyph/lane declared — each derives independently.
        #expect(lint.glyph == WikiEventTypeRegistry.derivedGlyph)
        #expect(lint.color == WikiEventTypeRegistry.derivedColor(for: "lint"))
        #expect(lint.producesChanges == false)
    }

    /// A definition page with no `event_kind` matches no event. Inferring the
    /// kind from the title or slug would silently claim a wire value the wiki
    /// never stated.
    @Test("a definition page without event_kind defines nothing")
    internal func pageWithoutKindIsSkipped() {
        let registry = Fixtures.registry([Fixtures.bare])
        #expect(registry.isEmpty)
        #expect(registry.declaredTypes.isEmpty)
    }

    @Test("only event-type pages are definitions — ordinary pages are ignored")
    internal func onlyDefinitionPagesCount() {
        let entity = Fixtures.page(id: "ingest", title: "Ingest", type: "entity")
        #expect(Fixtures.registry([entity]).isEmpty)
    }

    /// Two pages claiming one kind is a wiki lint's problem; the client's job
    /// is to pick the same one every launch rather than flap between them.
    @Test("duplicate kinds resolve deterministically, first slug wins")
    internal func duplicateKindsAreDeterministic() {
        let alpha = Fixtures.page(id: "aaa-ingest", title: "Alpha")
        let omega = Fixtures.page(id: "zzz-ingest", title: "Omega")
        let frontmatter = { (page: WikiPage) in ["event_kind": "ingest", "title": page.title] }

        let forward = WikiEventTypeRegistry.build(pages: [alpha, omega], frontmatter: frontmatter)
        let reversed = WikiEventTypeRegistry.build(pages: [omega, alpha], frontmatter: frontmatter)
        #expect(forward.resolve("ingest").label == "Alpha")
        // Payload order must not change the answer.
        #expect(reversed.resolve("ingest").label == "Alpha")
    }

    @Test("declared types sort by lane, and undeclared-lane pages follow declared ones")
    internal func declaredTypesSortByLane() {
        let registry = Fixtures.registry([Fixtures.ingest, Fixtures.lint])
        let kinds = registry.declaredTypes.map(\.kind)
        // ingest declares lane 10; lint declares none and gets a default well
        // above it, so ingest leads.
        #expect(kinds == ["ingest", "lint"])
        #expect(registry.declaredTypes.first?.lane == 10)
        #expect((registry.declaredTypes.last?.lane ?? 0) >= WikiEventTypeRegistry.defaultDeclaredLane)
    }

    @Test("produces_changes collects the kinds whose coverage is assertable")
    internal func changeProducingKinds() {
        let registry = Fixtures.registry([Fixtures.ingest, Fixtures.lint])
        #expect(registry.changeProducingKinds == ["ingest"])
    }
}

// MARK: - Resolving unknown kinds

@Suite("Wiki Event Type Registry — derived fallback")
internal struct WikiEventTypeRegistryFallbackTests {

    /// The pre-seed state, and the property that makes this safe to ship before
    /// any wiki has a single definition page: an empty registry still answers
    /// every lookup, so no surface loses its data.
    @Test("an empty registry resolves every kind rather than failing")
    internal func emptyRegistryStillResolves() {
        let type = WikiEventTypeRegistry.empty.resolve("github_pr")
        #expect(WikiEventTypeRegistry.empty.isEmpty)
        #expect(type.isDeclared == false)
        #expect(type.kind == "github_pr")
        #expect(type.label == "Github pr")
        #expect(type.pagePath == nil)
    }

    /// The bug this pins: the enum this replaces folded every unrecognized
    /// source into one grey `.other` bucket, so three unknown sources were
    /// indistinguishable on the plot. Distinct kinds must get distinct colors.
    @Test("two undeclared kinds get different colors, not one shared bucket")
    internal func undeclaredKindsStayDistinct() {
        let first = WikiEventTypeRegistry.derivedColor(for: "github_pr")
        let second = WikiEventTypeRegistry.derivedColor(for: "linear")
        #expect(first != second)
    }

    /// FNV-1a, not `Swift.Hasher` — the latter is salted per process, so a
    /// hashed palette would recolor every kind on each launch.
    @Test("a derived color is stable for the same kind")
    internal func derivedColorIsStable() {
        #expect(
            WikiEventTypeRegistry.derivedColor(for: "meeting_notes")
                == WikiEventTypeRegistry.derivedColor(for: "meeting_notes")
        )
    }

    @Test("derived labels humanize separators without mangling the wire value")
    internal func derivedLabels() {
        #expect(WikiEventTypeRegistry.derivedLabel(for: "process-inbox") == "Process inbox")
        #expect(WikiEventTypeRegistry.derivedLabel(for: "openrouter_stats") == "Openrouter stats")
        #expect(WikiEventTypeRegistry.derivedLabel(for: "ingest") == "Ingest")
        // Degenerate input survives rather than crashing or emptying.
        #expect(WikiEventTypeRegistry.derivedLabel(for: "").isEmpty)
    }

    @Test("surrounding whitespace on a wire kind still matches its declaration")
    internal func resolveTrimsWireKind() {
        let type = Fixtures.registry([Fixtures.ingest]).resolve("  ingest ")
        #expect(type.isDeclared)
        #expect(type.kind == "ingest")
    }
}

// MARK: - Provenance

@Suite("Wiki Provenance")
internal struct WikiProvenanceTests {

    /// The whole point of the two-state model: every shape a pre-enforcement
    /// backend can emit for "nothing recorded" must land on the same state, so
    /// no surface has to infer intent from a missing field.
    @Test("absent, null, and empty all decode to unknown")
    internal func absentAndEmptyAreUnknown() {
        #expect(WikiProvenance.decode(nil) == .unknown)
        #expect(WikiProvenance.decode([]) == .unknown)
        // Whitespace-only keys are noise, not provenance.
        #expect(WikiProvenance.decode(["", "  "]) == .unknown)
        #expect(WikiProvenance.decode(nil).isRecorded == false)
        #expect(WikiProvenance.decode(nil).events.isEmpty)
    }

    @Test("populated keys decode to events in wire order")
    internal func populatedDecodesToEvents() {
        let provenance = WikiProvenance.decode([
            "raw/articles/llama-cpp-release.md",
            "raw/papers/spec-decoding.md",
        ])
        #expect(provenance.isRecorded)
        #expect(provenance.events.map(\.key) == [
            "raw/articles/llama-cpp-release.md",
            "raw/papers/spec-decoding.md",
        ])
    }

    @Test("blank keys are dropped but real ones survive alongside them")
    internal func blankKeysDroppedFromPopulatedList() {
        let provenance = WikiProvenance.decode(["  ", "raw/articles/one.md"])
        #expect(provenance.events.map(\.key) == ["raw/articles/one.md"])
    }

    @Test("keys are trimmed so a padded wire value still joins")
    internal func keysAreTrimmed() {
        #expect(WikiProvenance.decode([" raw/a.md "]).events.first?.key == "raw/a.md")
    }

    /// A provenance row must render something legible from the key alone: the
    /// event feed is windowed, so the referenced event may not be loaded.
    @Test("an event ref labels itself from its key")
    internal func eventRefShortLabel() {
        #expect(WikiEventRef(key: "raw/articles/llama-cpp-release.md").shortLabel == "llama-cpp-release")
        #expect(WikiEventRef(key: "no-extension").shortLabel == "no-extension")
        #expect(WikiEventRef(key: "raw/a.b.c.md").shortLabel == "a.b.c")
        // A dotfile is all name, no extension — don't strip it to nothing.
        #expect(WikiEventRef(key: ".hidden").shortLabel == ".hidden")
    }

    @Test("the wire key matches the backend contract")
    internal func wireKeyIsPinned() {
        #expect(WikiProvenance.wireKey == "source_event_keys")
    }
}
