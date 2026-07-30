import Foundation

/// A scheduled cron job from the gateway's `cron.manage` (action: list) response.
struct CronJob: Identifiable, Equatable, Hashable {
    var id: String              // job_id
    var name: String            // human-readable name
    var schedule: String        // schedule_display e.g. "every 360m"
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastStatus: String?     // "ok", "error", etc
    var enabled: Bool
    var state: String           // "scheduled", "paused"
    var deliver: String         // "local", "telegram:...", etc
    var promptPreview: String?
    var prompt: String?
    /// The error detail from the last failed run, if the gateway reported one.
    var lastError: String?

    /// True when we only hold the server-truncated preview (the gateway caps
    /// `prompt_preview` at 100 chars and appends "…"), not the full prompt.
    /// A `describe` fetch replaces `prompt` with the untruncated text, which
    /// clears this: once `prompt` differs from `promptPreview` we have the whole
    /// thing.
    var isPromptTruncated: Bool {
        guard let preview = promptPreview else { return false }
        let looksTruncated = preview.hasSuffix("...") || preview.hasSuffix("…")
        // If we've fetched the full prompt it will differ from the preview.
        if let prompt, prompt != preview { return false }
        return looksTruncated
    }

    static func == (lhs: CronJob, rhs: CronJob) -> Bool {
        lhs.id == rhs.id
    }
}
