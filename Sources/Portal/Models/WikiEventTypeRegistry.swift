import SwiftUI

/// What an ingestion source IS, resolved from the wiki instead of compiled in.
///
/// An event type is an ordinary wiki page (`type: event-type`) whose frontmatter
/// declares the wire value it matches plus how to draw it:
///
/// ```yaml
/// type: event-type
/// title: Source ingest
/// event_kind: ingest          # matches the wire `trigger` / event kind
/// color: "3987e5"             # optional — else derived from event_kind
/// glyph: tray.and.arrow.down  # optional SF Symbol
/// lane: 10                    # optional sort weight
/// produces_changes: true      # this kind is expected to carry provenance
/// ```
///
/// The point is that adding an ingestion source becomes a page commit rather
/// than a client release. The taxonomy it replaces was a closed Swift enum
/// (`WikiChangeset.Trigger`: ingest | query | lint | process-inbox | manual)
/// with a hardcoded palette beside it, so every unrecognized source collapsed
/// into one indistinguishable bucket and a new one shipped with the app.
///
/// A wiki with no `event-type` pages resolves everything through the derived
/// fallback below, which is what keeps this safe to land before any wiki has
/// been seeded: nothing regresses, kinds simply stay unlabelled-but-distinct.
internal struct WikiEventTypeRegistry {

    /// One resolved event type. `isDeclared` records whether a wiki page
    /// actually defined this, so a surface can distinguish "the wiki says this
    /// is a GitHub PR" from "we've never heard of `github_pr` but here's a
    /// stable color for it".
    internal struct EventType: Equatable {
        internal let kind: String
        internal let label: String
        internal let color: Color
        internal let glyph: String
        internal let lane: Int
        internal let producesChanges: Bool
        internal let isDeclared: Bool
        /// Page path of the defining page, for click-through into the
        /// definition. nil for derived types — there's nothing to open.
        internal let pagePath: String?
    }

    /// The page `type:` value that marks a definition page.
    internal static let definitionPageType = "event-type"

    /// Frontmatter keys read off a definition page.
    internal static let kindKey = "event_kind"
    internal static let colorKey = "color"
    internal static let glyphKey = "glyph"
    internal static let laneKey = "lane"
    internal static let producesChangesKey = "produces_changes"

    /// Fallback glyph for a kind no page has defined.
    internal static let derivedGlyph = "circle.dotted"

    /// Sort weight for a type whose page declares no `lane`. Above the derived
    /// default so declared types lead, in declaration order.
    internal static let defaultDeclaredLane = 100
    /// Sort weight for derived (undeclared) types — they sort after every
    /// declared one.
    internal static let derivedLane = 1_000

    private let byKind: [String: EventType]

    /// Empty registry: every lookup derives. This is the pre-seed state and a
    /// legitimate steady state for a wiki that never defines event types.
    internal static let empty = WikiEventTypeRegistry(byKind: [:])

    private init(byKind: [String: EventType]) {
        self.byKind = byKind
    }

    // MARK: - Building

    /// Build from the pages of an already-loaded graph — no extra fetch. The
    /// definition pages arrive in the same `wiki.scan` payload every wiki
    /// surface already consumes.
    ///
    /// `frontmatter` supplies the per-page frontmatter the graph payload does
    /// not carry inline (`wiki.scan` returns a page's type and title but not
    /// arbitrary keys), so the caller decides how to source it: a page fetch,
    /// a scan extension, or a fixture in tests.
    internal static func build(
        pages: [WikiPage],
        frontmatter: (WikiPage) -> [String: String]
    ) -> WikiEventTypeRegistry {
        var byKind: [String: EventType] = [:]
        // Declaration order decides ties, so walk pages in a stable order
        // rather than whatever the payload happened to list.
        let definitions = pages
            .filter { $0.type == definitionPageType }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        for (offset, page) in definitions.enumerated() {
            let fm = frontmatter(page)
            // A definition page with no `event_kind` defines nothing — it
            // cannot be matched against any event. Skip rather than guess
            // from the title, which would silently claim a wire value.
            guard let kind = fm[kindKey]?.trimmingCharacters(in: .whitespaces),
                  !kind.isEmpty else { continue }
            // First declaration wins: two pages claiming one kind is a wiki
            // lint's problem, and picking deterministically beats flapping.
            guard byKind[kind] == nil else { continue }

            byKind[kind] = EventType(
                kind: kind,
                label: page.title.isEmpty ? Self.derivedLabel(for: kind) : page.title,
                color: fm[colorKey].flatMap { Color(hex: $0) } ?? Self.derivedColor(for: kind),
                glyph: fm[glyphKey]?.trimmingCharacters(in: .whitespaces).nonEmpty ?? derivedGlyph,
                lane: fm[laneKey].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    ?? (defaultDeclaredLane + offset),
                producesChanges: fm[producesChangesKey]?.lowercased() == "true",
                isDeclared: true,
                pagePath: page.path
            )
        }
        return WikiEventTypeRegistry(byKind: byKind)
    }

    // MARK: - Resolving

    /// The type for a wire kind — always answers. An undeclared kind resolves
    /// to a derived type rather than a shared "other" bucket, so two unknown
    /// sources stay visually distinct instead of merging into one color.
    internal func resolve(_ kind: String) -> EventType {
        let trimmed = kind.trimmingCharacters(in: .whitespaces)
        if let declared = byKind[trimmed] { return declared }
        return EventType(
            kind: trimmed,
            label: Self.derivedLabel(for: trimmed),
            color: Self.derivedColor(for: trimmed),
            glyph: Self.derivedGlyph,
            lane: Self.derivedLane,
            producesChanges: false,
            isDeclared: false,
            pagePath: nil
        )
    }

    /// Declared types in lane order — the legend / lane ordering for a chart.
    /// Derived types are absent by construction: a registry only knows what a
    /// page declared, and a surface adds the kinds it actually observed.
    internal var declaredTypes: [EventType] {
        byKind.values.sorted {
            ($0.lane, $0.kind) < ($1.lane, $1.kind)
        }
    }

    /// Whether any page has defined an event type. The events surface gates on
    /// this plus a non-empty log: a wiki with neither has nothing to show, and
    /// an affordance opening an empty plot is worse than no affordance.
    internal var isEmpty: Bool { byKind.isEmpty }

    /// Kinds a definition page marked `produces_changes: true` — the set whose
    /// provenance coverage is worth asserting.
    internal var changeProducingKinds: Set<String> {
        Set(byKind.values.filter(\.producesChanges).map(\.kind))
    }

    // MARK: - Derived presentation

    /// `"process-inbox"` → `"Process inbox"`. Deliberately gentle: the wire
    /// value is the truth and an over-clever title-caser that mangles
    /// `github_pr` into `Github Pr` reads worse than the raw string.
    internal static func derivedLabel(for kind: String) -> String {
        let spaced = kind
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return kind }
        return first.uppercased() + spaced.dropFirst()
    }

    /// A stable color for an undeclared kind, hashed off the wire value.
    ///
    /// FNV-1a via `Identicon.stableHash` — NOT `Swift.Hasher`, which is salted
    /// per process and would recolor every kind on each launch. Saturation and
    /// brightness are pinned to the band the app's other categorical palettes
    /// occupy so a derived color sits legibly on the dark surface instead of
    /// landing on near-black or a neon.
    internal static func derivedColor(for kind: String) -> Color {
        Color(
            hue: Double(Identicon.stableHash(kind) % 360) / 360.0,
            saturation: 0.55,
            brightness: 0.80
        )
    }
}

// MARK: -

private extension String {
    /// Self unless empty — lets `?? fallback` do the work at the call site.
    var nonEmpty: String? { isEmpty ? nil : self }
}
