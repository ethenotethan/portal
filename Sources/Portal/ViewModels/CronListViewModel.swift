import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CronListViewModel")

/// The subset of the upstream Hermes dashboard HTTP API the native cron view
/// needs: list, pause/resume (via `setCronJob`), and trigger. Declared as a
/// protocol so the view model routes to it without importing the concrete
/// client, and so tests can substitute a stub. `HermesStandardClient` already
/// implements every requirement.
internal protocol HermesStandardCronManaging: Sendable {
    func cronJobs() async throws -> [HermesStandardCronJob]
    func setCronJob(_ id: String, enabled: Bool) async throws
    func triggerCronJob(_ id: String) async throws
}

extension HermesStandardClient: HermesStandardCronManaging {}

@MainActor
@Observable
internal final class CronListViewModel {
    var jobs: [CronJob] = []
    var isLoading = false

    private var gatewayClient: GatewayClient?
    /// When set, cron reads/actions route to the upstream Hermes dashboard over
    /// HTTP instead of the WebSocket Gateway. A Standard backend is HTTP-only,
    /// so `gatewayClient` is left nil in that case and this drives everything.
    private var standardClient: (any HermesStandardCronManaging)?

    /// Standard's dashboard API exposes pause/resume/trigger but has no
    /// remove-job or edit-prompt endpoint, so the view hides those affordances
    /// when a Standard backend is the source. The WebSocket Gateway supports all.
    internal var supportsRemoveAndEdit: Bool { standardClient == nil }
    /// Trigger ("Run now") is a Standard-only affordance — the WebSocket path
    /// has no equivalent one-shot run action, so the button only shows there.
    internal var supportsTrigger: Bool { standardClient != nil }

    internal func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
        standardClient = nil
    }

    /// Point the view model at an upstream Hermes dashboard (Standard backend).
    /// Clears the WebSocket client so every read/action takes the HTTP path.
    internal func setStandardClient(_ client: any HermesStandardCronManaging) {
        standardClient = client
        gatewayClient = nil
    }

    func refreshJobs() async {
        if let standardClient {
            isLoading = true
            do {
                jobs = try await standardClient.cronJobs().map(CronJob.init(standard:))
                CronRunHistoryStore.shared.detectNewRuns(from: jobs)
                CronRunHistoryStore.shared.seedFromJobs(jobs)
            } catch {
                log.error("Failed to fetch Standard cron jobs: \(error)")
            }
            isLoading = false
            return
        }
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            jobs = try await client.listCronJobs()
            CronRunHistoryStore.shared.detectNewRuns(from: jobs)
            CronRunHistoryStore.shared.seedFromJobs(jobs)
        } catch {
            log.error("Failed to fetch cron jobs: \(error)")
        }
        isLoading = false
    }

    /// Run a job immediately. Standard-only — the WebSocket Gateway exposes no
    /// one-shot trigger, so this no-ops there (the button is hidden too).
    internal func triggerJob(id: String) async {
        guard let standardClient else { return }
        do {
            try await standardClient.triggerCronJob(id)
            await refreshJobs()
        } catch {
            log.error("Failed to trigger job \(id): \(error)")
        }
    }

    func pauseJob(id: String) async {
        if let standardClient {
            do {
                try await standardClient.setCronJob(id, enabled: false)
                await refreshJobs()
            } catch {
                log.error("Failed to pause Standard job \(id): \(error)")
            }
            return
        }
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("pause"),
                "name": AnyCodable(id)
            ])
            await refreshJobs()
        } catch {
            log.error("Failed to pause job \(id): \(error)")
        }
    }

    func resumeJob(id: String) async {
        if let standardClient {
            do {
                try await standardClient.setCronJob(id, enabled: true)
                await refreshJobs()
            } catch {
                log.error("Failed to resume Standard job \(id): \(error)")
            }
            return
        }
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("resume"),
                "name": AnyCodable(id)
            ])
            await refreshJobs()
        } catch {
            log.error("Failed to resume job \(id): \(error)")
        }
    }

    func removeJob(id: String) async {
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("remove"),
                "name": AnyCodable(id)
            ])
            await refreshJobs()
        } catch {
            log.error("Failed to remove job \(id): \(error)")
        }
    }

    /// Lazily fetch the full (untruncated) prompt for a job when its card
    /// expands, and splice it into the in-memory list so the view re-renders
    /// with the whole prompt. Gateway-only — Standard has no describe endpoint.
    internal func loadFullPrompt(id: String) async {
        guard let client = gatewayClient else { return }
        do {
            guard let full = try await client.describeCronJob(id: id) else { return }
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                jobs[idx].prompt = full.prompt
            }
        } catch {
            log.error("Failed to describe job \(id): \(error)")
        }
    }

    /// Fetch the execution ledger for a job and merge real per-run durations
    /// into the shared history store. Gateway-only.
    internal func loadHistory(id: String, limit: Int? = nil) async -> [CronRunRecord] {
        guard let client = gatewayClient else { return [] }
        do {
            return try await client.cronJobHistory(id: id, limit: limit)
        } catch {
            log.error("Failed to fetch history for job \(id): \(error)")
            return []
        }
    }

    func updatePrompt(id: String, newPrompt: String) async {
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("update"),
                "name": AnyCodable(id),
                "prompt": AnyCodable(newPrompt)
            ])
            await refreshJobs()
        } catch {
            log.error("Failed to update prompt for job \(id): \(error)")
        }
    }

    /// The `cron.manage` params for a rename, or nil when `newName` normalizes to
    /// nothing usable (the caller must not send it).
    ///
    /// Split out as a pure function purely so a test can pin the parameter names,
    /// because the RPC shape is asymmetric and silently wrong if confused:
    /// `cron.manage` already uses **`name` as the job identifier**, so the NEW
    /// name has to travel as **`job_name`**. Sending it as `name` addresses a job
    /// that doesn't exist; sending the id as `job_name` renames the job to its
    /// own id. Neither mistake fails loudly.
    internal static func renameParams(id: String, newName: String) -> [String: AnyCodable]? {
        // Normalized in the model, not just the view: every caller renaming a job
        // is writing a category path, and a trailing slash would otherwise persist.
        guard let normalized = CronCategory.normalize(name: newName) else { return nil }
        return [
            "action": AnyCodable("update"),
            "name": AnyCodable(id),
            "job_name": AnyCodable(normalized)
        ]
    }

    /// Rename a job — which, because `CronCategory` derives the category path
    /// from the name, is also how an existing job gets refiled into a category
    /// (`db-backup` → `infra/db-backup`). No migration and no separate schema:
    /// the next `list` groups it under its new path.
    ///
    /// Gateway-only — Standard's dashboard API has no update endpoint, which is
    /// what `supportsRemoveAndEdit` gates the affordance on.
    internal func renameJob(id: String, newName: String) async {
        guard let client = gatewayClient else { return }
        guard let params = Self.renameParams(id: id, newName: newName) else {
            log.error("Refusing to rename job \(id) to an empty name")
            return
        }
        do {
            let _ = try await client.call("cron.manage", params: params)
            await refreshJobs()
        } catch {
            log.error("Failed to rename job \(id): \(error)")
        }
    }
}
