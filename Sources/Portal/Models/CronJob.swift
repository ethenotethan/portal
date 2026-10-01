import Foundation

/// A scheduled cron job from the gateway's `cron.manage` (action: list) response.
internal struct CronJob: Identifiable, Equatable, Hashable {
    internal var id: String              // job_id
    internal var name: String            // human-readable name
    internal var schedule: String        // schedule_display e.g. "every 360m"
    internal var nextRunAt: Date?
    internal var lastRunAt: Date?
    internal var lastStatus: String?     // "ok", "error", etc
    internal var enabled: Bool
    internal var state: String           // "scheduled", "paused"
    internal var deliver: String         // "local", "telegram:...", etc
    internal var promptPreview: String?
    internal var prompt: String?
    /// The error detail from the last failed run, if the gateway reported one.
    internal var lastError: String?

    /// True when we only hold the server-truncated preview (the gateway caps
    /// `prompt_preview` at 100 chars and appends "…"), not the full prompt.
    /// A `describe` fetch replaces `prompt` with the untruncated text, which
    /// clears this: once `prompt` differs from `promptPreview` we have the whole
    /// thing.
    internal var isPromptTruncated: Bool {
        guard let preview = promptPreview else { return false }
        let looksTruncated = preview.hasSuffix("...") || preview.hasSuffix("…")
        // If we've fetched the full prompt it will differ from the preview.
        if let prompt, prompt != preview { return false }
        return looksTruncated
    }

    /// Whether `preview` is the gateway's preview of `full`: identical, or
    /// `full` begins with the preview minus its trailing ellipsis (the gateway
    /// caps at 100 characters and appends `...`). No preview at all contradicts
    /// nothing. This is the check that lets a fetched full prompt outlive a
    /// `list` refresh without ever masking an edit made somewhere else.
    internal static func previewMatches(full: String, preview: String?) -> Bool {
        guard let preview else { return true }
        if preview == full { return true }
        var stem = preview
        if stem.hasSuffix("...") {
            stem.removeLast(3)
        } else if stem.hasSuffix("…") {
            stem.removeLast()
        } else {
            return false
        }
        return !stem.isEmpty && full.hasPrefix(stem)
    }

    internal static func == (lhs: CronJob, rhs: CronJob) -> Bool {
        lhs.id == rhs.id
    }

    internal func hash(into hasher: inout Hasher) {
        // Equality is identity-based so refreshed wire fields still represent
        // the same job. Hashing must use that exact identity too: Set and
        // Dictionary require equal values to produce equal hashes.
        hasher.combine(id)
    }
}
