import Foundation

/// One recorded revision of a cron job's *definition* — what the job is (prompt,
/// model, schedule, skills, script, delivery…), as distinct from how it is wired
/// into the dataflow graph. Served by the gateway's `cron.manage` action
/// `revisions`, read out of the same changeset log the Revisions drawer uses, so
/// the two can never disagree about when something changed.
///
/// `definition` is the job as it stood at this revision (nil once deleted);
/// `changes` are the field-level differences against the revision before it. A
/// row written before the harness recorded definitions can only say the job was
/// present (`definitionRecorded == false`) — it is shown, not hidden, so the
/// history is honest about where it begins.
internal struct CronJobRevision: Identifiable, Equatable {
    internal let id: String
    internal let timestamp: String
    internal let action: String
    internal let actor: CronChangesetActor
    internal let summary: String
    internal let gitCommit: String
    internal let definition: [String: AnyCodable]?
    internal let changes: [CronDefinitionChange]
    internal let definitionRecorded: Bool

    internal init(
        id: String,
        timestamp: String,
        action: String,
        actor: CronChangesetActor,
        summary: String,
        gitCommit: String,
        definition: [String: AnyCodable]?,
        changes: [CronDefinitionChange],
        definitionRecorded: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.actor = actor
        self.summary = summary
        self.gitCommit = gitCommit
        self.definition = definition
        self.changes = changes
        self.definitionRecorded = definitionRecorded
    }

    /// Parsed instant, or nil when the timestamp is missing or unparseable;
    /// the same two ISO-8601 forms `CronChangeset.date` accepts.
    internal var date: Date? {
        guard !timestamp.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: timestamp) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp)
    }

    /// The fields this revision touched, in the harness's field order.
    internal var changedFields: [String] {
        var seen: [String] = []
        for change in changes where !seen.contains(change.field) {
            seen.append(change.field)
        }
        return seen
    }
}

/// One field of a job definition before and after a revision. Values are kept
/// as the wire sent them (strings, lists, booleans, numbers, or absent) and
/// rendered for people by `displayText`.
internal struct CronDefinitionChange: Equatable {
    internal let field: String
    internal let before: AnyCodable?
    internal let after: AnyCodable?

    internal init(field: String, before: AnyCodable?, after: AnyCodable?) {
        self.field = field
        self.before = before
        self.after = after
    }

    /// A field value as a person reads it: text as is, lists joined, booleans
    /// as yes/no, absent as an em dash. Never `nil` and never `"null"`.
    internal static func displayText(_ value: AnyCodable?) -> String {
        guard let value else { return "—" }
        if let text = value.stringValue { return text.isEmpty ? "—" : text }
        if let flag = value.boolValue { return flag ? "yes" : "no" }
        if let number = value.intValue { return String(number) }
        if let number = value.doubleValue { return String(number) }
        if let items = value.arrayValue {
            let parts = items.map { displayText($0) }.filter { $0 != "—" }
            return parts.isEmpty ? "—" : parts.joined(separator: ", ")
        }
        if let dict = value.dictionaryValue {
            return dict.keys.sorted().map { "\($0): \(displayText(dict[$0]))" }.joined(separator: ", ")
        }
        return "—"
    }

    internal var beforeText: String { Self.displayText(before) }
    internal var afterText: String { Self.displayText(after) }
}

/// One page of a job's revisions, newest first. `total` counts the whole
/// history, not the page, so a short page reads as the end of the history.
internal struct CronJobRevisionsPage: Equatable {
    internal let jobID: String
    internal let jobName: String?
    internal let revisions: [CronJobRevision]
    internal let total: Int
    internal let limit: Int
    internal let offset: Int
}

/// What a card learned about a job's definition history: the page, or the fact
/// that this gateway does not serve one (an older harness answers `revisions`
/// with "unknown cron action"). The two are different states on screen.
internal enum CronJobRevisionsResult: Equatable {
    case loaded(CronJobRevisionsPage)
    case unsupported
    case failed
}
