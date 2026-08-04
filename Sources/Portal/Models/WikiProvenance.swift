import Foundation

/// Why a wiki change happened — the events that caused it, or an honest
/// admission that nobody recorded them.
///
/// Deliberately two states, not three. An earlier draft distinguished "no
/// cause exists" from "cause not recorded" by inferring intent from the
/// changeset's trigger, but that inference is guesswork: `wiki_capture_changeset`
/// defaults `source` to `""`, so an empty value means *either* and the log
/// cannot tell you which. Collapsing them refuses the guess.
///
/// `unknown` is only trustworthy if it stays rare going forward, which is why
/// the backend counterpart to this type is an enforcement rule: every new
/// changeset must declare provenance — events, or explicitly none-with-reason.
/// Then `unknown` means precisely "this predates enforcement" and its count
/// only shrinks.
internal enum WikiProvenance: Equatable, Hashable {
    /// No provenance recorded. Not a claim that none exists.
    case unknown
    /// The events that caused this change, in the order the backend listed
    /// them. Never empty — an empty list decodes to `.unknown`, since a writer
    /// that recorded "no events" and a writer that recorded nothing are
    /// indistinguishable on the wire.
    case events([WikiEventRef])

    /// Wire key on a changeset payload.
    internal static let wireKey = "source_event_keys"

    /// Decode from a changeset's `source_event_keys`, tolerating every shape a
    /// pre-enforcement backend can emit: absent, null, empty, or populated.
    /// All of the first three are `.unknown`.
    internal static func decode(_ keys: [String]?) -> WikiProvenance {
        let refs = (keys ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(WikiEventRef.init(key:))
        return refs.isEmpty ? .unknown : .events(refs)
    }

    /// Decode with the legacy single-`source` field folded in.
    ///
    /// A gateway predating provenance sends `source` and no keys array;
    /// folding it here means the surface shows real provenance against an
    /// un-upgraded gateway instead of a wall of `unknown`. This mirrors the
    /// gateway's own read-time migration rather than inventing anything —
    /// `source` IS a recorded cause, just a singular one.
    ///
    /// The keys array wins whenever it has entries: an enforcing gateway has
    /// already folded `source` in as the first key, so re-adding it would
    /// duplicate that entry.
    internal static func decode(_ keys: [String]?, legacySource: String) -> WikiProvenance {
        if let keys, !keys.isEmpty { return decode(keys) }
        return decode([legacySource])
    }

    /// The referenced events (empty when unknown).
    internal var events: [WikiEventRef] {
        switch self {
        case .unknown: return []
        case .events(let refs): return refs
        }
    }

    /// Whether provenance was recorded at all — drives whether a surface shows
    /// links or the "not recorded" note.
    internal var isRecorded: Bool {
        if case .events = self { return true }
        return false
    }
}

/// A reference to one ingestion event, by the key the backend joins on.
///
/// On Hermes that key is the raw source's path within the wiki
/// (`raw/articles/llama-cpp-release.md`) — sources are immutable files, so the
/// path is a stable identity and the file itself carries the event's URL and
/// ingest time. The client treats the key as opaque: it joins and displays,
/// never parses semantics out of it.
internal struct WikiEventRef: Equatable, Hashable, Identifiable {
    internal let key: String

    internal var id: String { key }

    /// Last path component without its extension —
    /// `raw/articles/llama-cpp-release.md` → `llama-cpp-release`. A chip label
    /// for when the event itself hasn't been loaded (the feed may be a window
    /// that doesn't include this event, or not fetched yet), so a provenance
    /// row can render something legible from the key alone.
    internal var shortLabel: String {
        let lastComponent = key.split(separator: "/").last.map(String.init) ?? key
        guard let dot = lastComponent.lastIndex(of: "."), dot != lastComponent.startIndex else {
            return lastComponent
        }
        return String(lastComponent[..<dot])
    }
}
