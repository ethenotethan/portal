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

    static func == (lhs: CronJob, rhs: CronJob) -> Bool {
        lhs.id == rhs.id
    }
}
