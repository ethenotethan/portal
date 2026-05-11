import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "CronListViewModel")

@MainActor
@Observable
final class CronListViewModel {
    var jobs: [CronJob] = []
    var isLoading = false

    private var gatewayClient: GatewayClient?

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    func refreshJobs() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            jobs = try await client.listCronJobs()
            CronRunHistoryStore.shared.detectNewRuns(from: jobs)
            await fetchFullPrompts(client)
        } catch {
            log.error("Failed to fetch cron jobs: \(error)")
        }
        isLoading = false
    }

    private func fetchFullPrompts(_ client: GatewayClient) async {
        await withTaskGroup(of: (Int, CronJob?).self) { group in
            for (index, job) in jobs.enumerated() {
                let hasFullPrompt = job.prompt != nil && job.prompt != job.promptPreview
                if hasFullPrompt { continue }
                group.addTask { (index, try? await client.getCronJob(id: job.id)) }
            }
            for await (index, fullJob) in group {
                guard let fullJob else { continue }
                jobs[index] = fullJob
            }
        }
        CronRunHistoryStore.shared.seedFromJobs(jobs)
        CronRunHistoryStore.shared.detectNewRuns(from: jobs)
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
}
