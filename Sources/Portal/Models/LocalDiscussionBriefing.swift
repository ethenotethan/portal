import Foundation

/// What else is going on this machine, summarized for the on-device model.
///
/// The local model has no tools, no gateway, and no filesystem — so asked "what
/// are we working on today?" it can only apologize. This is the fix: a short
/// digest of the other sessions, baked into the system prompt before the first
/// question, so the discussion starts with something to anchor to.
///
/// Metadata only, deliberately: each session's title, how long ago it was
/// touched, and the one-line preview the sidebar already shows. No transcripts,
/// no file contents, no diffs. It never leaves the machine (the briefing goes
/// straight into `LocalDiscussion.instructions()`, which is fed to MLX
/// in-process), but a small model handed 12 full transcripts would answer about
/// none of them, so the budget is the real constraint.
internal struct LocalDiscussionBriefing: Sendable, Equatable {
    /// One session, reduced to what is worth a line of prompt.
    internal struct Entry: Sendable, Equatable {
        internal let title: String
        /// Human phrasing of `lastActive` — "active now", "2h ago", "yesterday".
        /// Empty when the session carries no timestamps at all.
        internal let age: String
        /// The sidebar's last-message preview, trimmed and de-quoted. Often empty.
        internal let preview: String
        /// The session the user is sitting in, which the model should treat as
        /// "here" rather than as one more thing on the list.
        internal let isCurrent: Bool
        internal let isPinned: Bool
    }

    /// Most recently active first, with the current session promoted to the top.
    internal let entries: [Entry]
    /// How many sessions the digest was drawn from, which can exceed
    /// `entries.count` — "3 of 27" is itself useful context.
    internal let totalSessions: Int

    internal static let empty = LocalDiscussionBriefing(entries: [], totalSessions: 0)

    /// How many sessions get a line. Past a handful a 4B model starts answering
    /// about the wrong one, and the list crowds out the actual question.
    internal static let maxSessions = 8
    /// Characters of preview per session. A preview is a sentence fragment; more
    /// than this is a paragraph the model will quote back verbatim.
    internal static let previewBudget = 140

    // MARK: - Building

    /// Digest the session list, newest first.
    ///
    /// Archived sessions are dropped (the user filed them away) and so are ones
    /// with neither a title nor a preview — a bullet reading "Untitled" teaches
    /// the model nothing and costs it attention.
    internal static func build(
        from sessions: [Session],
        currentSessionID: String? = nil,
        now: Date = Date()
    ) -> LocalDiscussionBriefing {
        let usable = sessions.filter { !$0.isArchived }
        let ranked = usable.sorted { lhs, rhs in
            // The current session first: everything else is context for it.
            let lhsIsCurrent = isCurrent(lhs, currentSessionID)
            let rhsIsCurrent = isCurrent(rhs, currentSessionID)
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            return activity(of: lhs) > activity(of: rhs)
        }

        var entries: [Entry] = []
        for session in ranked where entries.count < maxSessions {
            guard let entry = entry(for: session, currentSessionID: currentSessionID, now: now) else { continue }
            entries.append(entry)
        }
        return LocalDiscussionBriefing(entries: entries, totalSessions: usable.count)
    }

    /// Chat holds whichever id it was handed — the database key for a resumed
    /// session, the short gateway hex for one it created — so both are checked.
    /// Getting it wrong only costs the "we are in this one" marker, but that
    /// marker is what stops the model listing the current thread as news.
    private static func isCurrent(_ session: Session, _ currentSessionID: String?) -> Bool {
        guard let currentSessionID, !currentSessionID.isEmpty else { return false }
        return session.id == currentSessionID || session.gatewayID == currentSessionID
    }

    private static func activity(of session: Session) -> Date {
        session.lastActive ?? session.startedAt ?? .distantPast
    }

    private static func entry(for session: Session, currentSessionID: String?, now: Date) -> Entry? {
        let title = resolvedTitle(of: session)
        let preview = cleanPreview(session.preview, title: title)
        guard !title.isEmpty || !preview.isEmpty else { return nil }
        return Entry(
            title: title.isEmpty ? "Untitled session" : title,
            age: age(of: session, now: now),
            preview: preview,
            isCurrent: isCurrent(session, currentSessionID),
            isPinned: session.isPinned
        )
    }

    /// A user's own rename wins over the gateway's generated title — it is the
    /// name they'd use out loud, which is the name the model should answer to.
    private static func resolvedTitle(of session: Session) -> String {
        for candidate in [session.localTitle, session.title] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Collapse the preview to one line and cut it to budget. Quote marks come
    /// out because the prompt puts the preview *in* quotes; a stray one there
    /// reads to the model as the end of the quoted text.
    private static func cleanPreview(_ raw: String?, title: String) -> String {
        guard let raw else { return "" }
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Many sessions are titled from their first message, so the preview and
        // the title are the same sentence. Saying it twice wastes the budget.
        guard flattened != title else { return "" }
        guard flattened.count > previewBudget else { return flattened }
        return String(flattened.prefix(previewBudget)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// "active now" / "14m ago" / "3h ago" / "yesterday" / "5d ago".
    ///
    /// Coarse on purpose: the model is going to say this out loud, and "two
    /// hours ago" is what a person would say about something touched at 134
    /// minutes. `RelativeDateTimeFormatter` is avoided here because it localizes
    /// into text the prompt then mixes with English instructions.
    internal static func age(of session: Session, now: Date) -> String {
        guard let stamp = session.lastActive ?? session.startedAt else { return "" }
        let seconds = now.timeIntervalSince(stamp)
        guard seconds >= 0 else { return "active now" }
        let minutes = Int(seconds / 60)
        if minutes < 2 { return "active now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        return weeks == 1 ? "last week" : "\(weeks) weeks ago"
    }

    // MARK: - Prompting

    /// The block that goes into the system prompt, or nil when there is nothing
    /// to say — an empty heading would only invite the model to invent entries.
    internal var promptBlock: String? {
        guard !entries.isEmpty else { return nil }
        let lines = entries.map { entry -> String in
            var line = "- \(entry.title)"
            if entry.isCurrent { line += " (the session we are in right now)" }
            if entry.isPinned { line += " (pinned)" }
            if !entry.age.isEmpty { line += " \u{2014} \(entry.age)" }
            if !entry.preview.isEmpty { line += "\n    last message: \"\(entry.preview)\"" }
            return line
        }
        let scope = totalSessions > entries.count
            ? "\(entries.count) of \(totalSessions) agent sessions"
            : "\(entries.count) agent session\(entries.count == 1 ? "" : "s")"
        return """
        Recent work on this machine (\(scope), most recent first):
        \(lines.joined(separator: "\n"))
        """
    }
}
