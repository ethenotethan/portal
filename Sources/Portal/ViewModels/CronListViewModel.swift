import Foundation
import SwiftUI
import os

private let log = PortalLogger(category: "CronListViewModel")

@MainActor
@Observable
internal final class CronListViewModel {
    var jobs: [CronJob] = []
    var isLoading = false

    /// The cron interflow graph, loaded alongside the job list so a card can
    /// list its own inputs, outputs, and side effects. Empty against a harness
    /// too old to answer `cron.graph` — a card then simply omits its dataflow
    /// section.
    internal private(set) var graph: CronGraph = .empty

    /// Why the last move/rename failed, or nil when the last one succeeded.
    ///
    /// A failed rename used to be logged and dropped, which made it
    /// indistinguishable from success: the editor closed, the list refreshed
    /// unchanged, and the job sat where it started. That reads as "the feature
    /// doesn't work" rather than "the write was rejected" — and the two have very
    /// different fixes. `cron.manage` only grew its `update` action recently, so a
    /// harness on an older build answers `unknown cron action` (error 4016), which
    /// is exactly the case a silent catch hides.
    ///
    /// Settable from the view so dismissing the banner is `renameError = nil`
    /// rather than a one-line method. A dedicated clear method would only ever be
    /// called from SwiftUI, which Periphery can't see through — it reads as an
    /// unused declaration and trips the dead-code ratchet.
    internal var renameError: String?

    /// Why the last prompt save was refused, or nil when it went through. Same
    /// reasoning as `renameError`: `cron.manage` answers a refusal in-band
    /// (`response.error`) rather than by throwing, so a save the gateway
    /// rejected used to be indistinguishable from one it accepted.
    internal var promptError: String?

    private var gatewayClient: GatewayClient?

    internal func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    func refreshJobs() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            let fetched = try await client.listCronJobs()
            jobs = Self.preservingFetchedPrompts(in: fetched, from: jobs)
            CronRunHistoryStore.shared.detectNewRuns(from: jobs)
            CronRunHistoryStore.shared.seedFromJobs(jobs)
        } catch {
            log.error("Failed to fetch cron jobs: \(error)")
        }
        await loadGraph(client: client)
        isLoading = false
    }

    /// Fetch the interflow graph so cards can show per-job dataflow. Non-fatal
    /// and independent of the job fetch: a failure (older harness that lacks
    /// `cron.graph`) leaves the previous graph in place rather than blanking the
    /// dataflow that other cards are already showing.
    private func loadGraph(client: GatewayClient) async {
        do {
            graph = try await client.cronGraph()
        } catch {
            log.error("Failed to fetch cron graph: \(error)")
        }
    }

    /// Carry full prompts already fetched by `describe` across a `list` refresh.
    ///
    /// `list` only ever carries the 100-character `prompt_preview`, so replacing
    /// the array wholesale threw away every full prompt the moment the poller
    /// ticked or a save refreshed the list — the card snapped back to the preview
    /// and its "may be truncated" badge, which read as the fetch never having
    /// worked. A kept prompt must still *match* the fresh preview (same text up
    /// to the ellipsis); otherwise an edit made elsewhere would be masked by the
    /// stale text, and the next expand re-fetches instead.
    nonisolated internal static func preservingFetchedPrompts(in fresh: [CronJob], from previous: [CronJob]) -> [CronJob] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { job in
            guard job.prompt == nil,
                  let full = previousByID[job.id]?.prompt,
                  CronJob.previewMatches(full: full, preview: job.promptPreview) else { return job }
            var kept = job
            kept.prompt = full
            return kept
        }
    }

    /// The inputs / outputs / side effects for one job, projected from the
    /// interflow graph. Empty until the graph loads or when the job declares no
    /// dataflow.
    internal func dataflow(for jobID: String) -> CronJobDataflow {
        graph.dataflow(forCronID: jobID)
    }

    func pauseJob(id: String) async {
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
    /// with the whole prompt.
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
            let response = try await client.call("cron.manage", params: [
                "action": AnyCodable("update"),
                "name": AnyCodable(id),
                "prompt": AnyCodable(newPrompt)
            ])
            if let error = response.error {
                // An RPC-level refusal doesn't throw, so without this the editor
                // closed, the list refreshed unchanged, and a rejected save (or a
                // harness without `update`, error 4016) looked like a success.
                log.error("Gateway refused prompt update for job \(id): \(error.code) \(error.message)")
                promptError = error.message
                return
            }
            promptError = nil
            // The refresh below only brings back the preview; hold the text just
            // saved as the full prompt so the card doesn't snap to a truncated
            // copy of what was typed a moment ago.
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                jobs[idx].prompt = newPrompt
            }
            await refreshJobs()
        } catch {
            log.error("Failed to update prompt for job \(id): \(error)")
            promptError = error.localizedDescription
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
    /// Renaming a job is an edit to its whole category path.
    internal func renameJob(id: String, newName: String) async {
        guard let client = gatewayClient else {
            renameError = "This harness can't move jobs — its API has no update endpoint."
            return
        }
        guard let params = Self.renameParams(id: id, newName: newName) else {
            log.error("Refusing to rename job \(id) to an empty name")
            renameError = "That name is empty once the slashes are collapsed."
            return
        }
        do {
            let _ = try await client.call("cron.manage", params: params)
            renameError = nil
            await refreshJobs()
        } catch {
            log.error("Failed to rename job \(id): \(error)")
            renameError = Self.renameFailureMessage(for: error)
        }
    }

    /// Turn a `cron.manage` rename failure into something that tells the user what
    /// to do about it.
    ///
    /// The case worth naming is a gateway predating the `update` action: it answers
    /// `unknown cron action: update`, which as raw text reads like a Portal bug. It
    /// isn't — it's a version skew, and the fix is updating the harness, so the
    /// message says that instead of echoing the wire error.
    internal static func renameFailureMessage(for error: any Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("unknown cron action") {
            return "This harness's gateway is too old to move jobs — it doesn't "
                + "support cron.manage 'update'. Update the harness and try again."
        }
        return "Couldn't move the job: \(error.localizedDescription)"
    }
}
