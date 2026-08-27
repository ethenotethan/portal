import Foundation

// MARK: - CronChangeset

/// One change to the dataflow graph's configuration as the *gateway* recorded
/// it (`cron.changesets`).
///
/// The distance between this and `CronGraphRevision` is the whole point of the
/// backend layer: a revision is what Portal noticed while polling every 10
/// seconds, a changeset is what the gateway wrote down when the change actually
/// happened. Three things only this one can carry —
///
/// - **real time.** A change made and reverted between two polls exists here and
///   nowhere else.
/// - **an actor.** A cron change comes from a person in the UI, an agent calling
///   `cron.manage`, or the scheduler itself, and the observed log can't tell.
/// - **provenance**, the "why": the session/turn that rewired the graph.
///
/// Everything else it shares with the observed log on purpose: the digest, the
/// parent digest, and a graph per revision, so both sources produce the same
/// `CronGraphDiff` statements and the drawer renders them the same way.
internal struct CronChangeset: Identifiable, Equatable {

    internal let id: String

    /// ISO 8601, verbatim. Kept as the wire string with `date` doing the parsing
    /// so an unparseable value degrades to "no time" rather than to some
    /// plausible wrong instant — the same choice `WikiChangeset` makes.
    internal let timestamp: String

    /// What the gateway calls this change, verbatim and open-vocabulary.
    ///
    /// Deliberately not an enum: the row's sentences come from the diff, which
    /// this app derives itself, so a value it doesn't recognize costs nothing.
    /// An enum would fold every unknown action into one bucket and tempt a
    /// future reader into believing the list is complete.
    internal let action: String

    /// The job this change is about, when the gateway scopes it to one. Empty
    /// for a change that isn't about a single job.
    internal let job: String

    /// The commitment after the change, and the one before it. `parentDigest` is
    /// nil when the wire didn't carry one, which for the oldest recorded change
    /// is the truth and otherwise means the gateway couldn't say — the same
    /// distinction `CronGraphRevisionStore.diff(for:)` turns on, resolved the
    /// same way there.
    internal let digest: String
    internal let parentDigest: String?

    internal let actor: CronChangesetActor

    /// The gateway's own one-line description, if it wrote one. Shown *beside*
    /// the derived statements, never instead of them: a summary is prose someone
    /// wrote, and the statements are what the graphs actually differ by.
    internal let summary: String

    /// Which session/turn caused this — `.unknown` when nobody recorded one.
    internal let provenance: CronChangesetProvenance

    /// Short git hash when job definitions are file-backed, else empty.
    internal let gitCommit: String

    internal init(
        id: String,
        timestamp: String,
        action: String,
        job: String,
        digest: String,
        parentDigest: String?,
        actor: CronChangesetActor,
        summary: String,
        provenance: CronChangesetProvenance,
        gitCommit: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.job = job
        self.digest = digest
        self.parentDigest = parentDigest
        self.actor = actor
        self.summary = summary
        self.provenance = provenance
        self.gitCommit = gitCommit
    }

    /// Parsed instant, or nil when the timestamp is missing or unparseable.
    /// Fractional seconds are accepted because gateways emit both forms.
    internal var date: Date? {
        guard !timestamp.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: timestamp) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp)
    }

    /// The same 12-hex display form the commitment chip and the observed log
    /// use, so a digest from either source is recognizably the same thing.
    internal var shortDigest: String {
        String(digest.prefix(CronGraphDigest.shortLength))
    }

    /// How to tint the row before its diff has been fetched.
    ///
    /// A guess from the action word, and only ever a placeholder: once the diff
    /// arrives the statements carry their own polarities and the tint stops
    /// mattering. Unrecognized actions read as an edit rather than as nothing,
    /// because "something changed" is the one thing a changeset guarantees.
    internal var polarity: CronGraphChange.Polarity {
        switch action.lowercased() {
        case "create", "created", "add", "added": return .added
        case "delete", "deleted", "remove", "removed": return .removed
        default: return .modified
        }
    }
}

// MARK: - CronChangesetsPage

/// Response envelope for `cron.changesets`, with the pagination cursor —
/// mirroring `WikiChangesetsPage` down to `hasMore` being counted from what
/// actually arrived, so a short page doesn't claim there's more when there isn't.
internal struct CronChangesetsPage: Equatable {
    internal let changesets: [CronChangeset]
    internal let total: Int
    internal let limit: Int
    internal let offset: Int

    internal var hasMore: Bool { offset + changesets.count < total }
}

// MARK: - CronChangesetActor

/// Who made a configuration change.
///
/// The wiki has no need for this — a page edit is an ingestion or a person, and
/// the trigger already says which. A cron change has three plausible authors
/// that behave differently, and "the scheduler disabled a job after N failures"
/// versus "someone disabled it" is exactly the kind of thing you open a history
/// to find out.
///
/// `unknown` means nothing was recorded. It is **not** a claim that nobody did
/// it, and `other` exists so a value this app doesn't know survives to the
/// screen instead of being flattened into `unknown` — which would turn a
/// recorded fact into an admission of ignorance.
internal enum CronChangesetActor: Equatable, Hashable {
    case human
    case agent
    case scheduler
    case other(String)
    case unknown

    /// Exact matches only. A gateway that says `user` gets `.other("user")`
    /// rather than being guessed into `.human`: the label still shows the word
    /// it sent, and nothing pretends to know it meant a person.
    internal init(raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "": self = .unknown
        case "human": self = .human
        case "agent": self = .agent
        case "scheduler": self = .scheduler
        default: self = .other(value)
        }
    }

    internal var label: String {
        switch self {
        case .human: return "a person"
        case .agent: return "an agent"
        case .scheduler: return "the scheduler"
        case .other(let value): return value
        case .unknown: return "not recorded"
        }
    }

    internal var icon: String {
        switch self {
        case .human: return "person"
        case .agent: return "sparkles"
        case .scheduler: return "clock"
        case .other: return "questionmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    internal var isRecorded: Bool {
        if case .unknown = self { return false }
        return true
    }
}

// MARK: - CronChangesetProvenance

/// Why a configuration change happened — the turns that caused it, or an honest
/// admission that nobody recorded them.
///
/// Two states, and `unknown` is not a claim that no cause exists: the same
/// discipline `WikiProvenance` is built on, and it's the discipline that
/// matters, not the code. Kept as its own type rather than shared with the
/// wiki's because the referent is different — a session/turn that called
/// `cron.manage`, not an ingestion event — and the wiki's legacy single-`source`
/// folding has no cron counterpart to fold. The day a third surface needs this
/// shape, it earns a generic; two don't.
internal enum CronChangesetProvenance: Equatable, Hashable {
    /// Nothing recorded. See above: not "there was no cause".
    case unknown
    /// The turns that caused this change, in the order the gateway listed them.
    /// Never empty — an empty list decodes to `.unknown`, because a gateway that
    /// recorded "no turns" and one that recorded nothing are indistinguishable
    /// on the wire.
    case turns([CronTurnRef])

    /// Wire key on a changeset payload, same name the wiki uses so a gateway
    /// implementing both doesn't need two vocabularies.
    internal static let wireKey = "source_event_keys"

    /// Tolerates every shape a gateway can send: absent, null, empty, or
    /// populated, with blank entries dropped. The first three are `.unknown`.
    internal static func decode(_ keys: [String]?) -> CronChangesetProvenance {
        let refs = (keys ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(CronTurnRef.init(key:))
        return refs.isEmpty ? .unknown : .turns(refs)
    }

    internal var turns: [CronTurnRef] {
        switch self {
        case .unknown: return []
        case .turns(let refs): return refs
        }
    }

    internal var isRecorded: Bool {
        if case .turns = self { return true }
        return false
    }
}

/// A reference to one conversation turn, by whatever key the gateway joins on.
///
/// Treated as opaque, exactly as `WikiEventRef` is: the client joins and
/// displays, and never parses meaning out of the key. A session key with a turn
/// suffix, a UUID, a run id — all the same to this type.
internal struct CronTurnRef: Equatable, Hashable, Identifiable {
    internal let key: String

    internal var id: String { key }

    /// A chip label for a turn that hasn't been resolved to a real conversation:
    /// the last `/`- or `:`-delimited component, capped so a raw UUID doesn't
    /// take the whole row.
    internal var shortLabel: String {
        let tail = key.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? key
        return tail.count > 12 ? String(tail.prefix(12)) + "…" : tail
    }
}
