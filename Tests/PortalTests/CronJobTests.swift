import Foundation
import Testing
@testable import Portal

@Suite("Cron job identity")
internal struct CronJobTests {
    @Test("refreshed wire fields do not change job identity or hashing")
    internal func refreshedFieldsPreserveIdentity() {
        let listed = CronJob(
            id: "daily-report",
            name: "Daily report",
            schedule: "every 24h",
            nextRunAt: Date(timeIntervalSince1970: 100),
            lastRunAt: nil,
            lastStatus: nil,
            enabled: true,
            state: "scheduled",
            deliver: "local",
            promptPreview: "Build the report...",
            prompt: nil,
            lastError: nil
        )
        let refreshed = CronJob(
            id: listed.id,
            name: "Renamed report",
            schedule: "every 12h",
            nextRunAt: Date(timeIntervalSince1970: 200),
            lastRunAt: Date(timeIntervalSince1970: 150),
            lastStatus: "error",
            enabled: false,
            state: "paused",
            deliver: "telegram:alerts",
            promptPreview: "Build the report and publish it...",
            prompt: "Build the report and publish it to the team.",
            lastError: "Gateway unavailable"
        )
        var jobs: Set<CronJob> = [listed]

        #expect(listed == refreshed)
        #expect(jobs.contains(refreshed))
        jobs.insert(refreshed)
        #expect(jobs.count == 1)
    }
}
