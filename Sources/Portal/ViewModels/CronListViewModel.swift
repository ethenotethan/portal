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

    internal func updateTags(id: String, tags: [String]) async {
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("update"),
                "name": AnyCodable(id),
                "tags": AnyCodable.array(tags.map(AnyCodable.init))
            ])
            await refreshJobs()
        } catch {
            log.error("Failed to update tags for job \(id): \(error)")
        }
    }
}
