import Foundation

/// Bridges the upstream Hermes dashboard's HTTP payloads (`HermesStandard*`)
/// into the native Portal models the shared list views render, so a focused
/// Standard backend feeds the same Cron/Skills surfaces the WebSocket Gateway
/// does instead of a bespoke read-only pane.
///
/// The shapes don't line up one-to-one: Standard's cron payload has no
/// next/last-run timestamps or prompt body, and its skills carry an
/// `enabled` flag the WebSocket `SkillInfo` never modeled. Fields with no
/// upstream source map to `nil`; the views gate the affordances that would
/// need them (see `CronListViewModel.supportsRemoveAndEdit`).

extension CronJob {
    /// A Standard cron job as a native `CronJob`. Timestamps and the prompt
    /// body have no HTTP source, so they stay `nil` — the row degrades to
    /// schedule + last-status, which is all the upstream API reports.
    internal init(standard job: HermesStandardCronJob) {
        self.init(
            id: job.id,
            name: job.name,
            schedule: job.schedule,
            nextRunAt: nil,
            lastRunAt: nil,
            lastStatus: job.lastRunStatus,
            enabled: job.enabled,
            state: job.state,
            deliver: job.deliver,
            promptPreview: nil,
            prompt: nil,
            lastError: job.lastRunError
        )
    }
}

extension SkillInfo {
    /// A Standard skill as a native `SkillInfo`. `provenance` maps to `source`;
    /// the slash command is synthesized from the name (the dashboard API doesn't
    /// return one). `enabled` is carried separately by the view model because
    /// `SkillInfo` predates a per-skill toggle.
    internal init(standard skill: HermesStandardSkill) {
        self.init(
            name: skill.name,
            description: skill.description,
            category: skill.category,
            source: skill.provenance,
            identifier: nil,
            tags: [],
            skillMdPath: nil,
            skillDir: nil,
            skillMdPreview: nil,
            skillMdFullContent: nil,
            slashCommand: "/\(skill.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
    }
}
