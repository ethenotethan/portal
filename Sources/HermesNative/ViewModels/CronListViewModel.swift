import Foundation
import SwiftUI

/// Manages the list of cron jobs and pause/resume/remove actions.
@MainActor
@Observable
final class CronListViewModel {
    var jobs: [CronJob] = []
    var isLoading = false

    private var gatewayClient: GatewayClient?

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    /// Refresh the cron job list from the gateway.
    func refreshJobs() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            jobs = try await client.listCronJobs()
        } catch {
            NSLog("[CronListViewModel] Failed to fetch cron jobs: \(error)")
        }
        isLoading = false
    }

    /// Pause a cron job by ID.
    func pauseJob(id: String) async {
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("pause"),
                "name": AnyCodable(id)
            ])
            // Refresh to get updated state
            await refreshJobs()
        } catch {
            NSLog("[CronListViewModel] Failed to pause job \(id): \(error)")
        }
    }

    /// Resume a paused cron job by ID.
    func resumeJob(id: String) async {
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("resume"),
                "name": AnyCodable(id)
            ])
            await refreshJobs()
        } catch {
            NSLog("[CronListViewModel] Failed to resume job \(id): \(error)")
        }
    }

    /// Remove a cron job by ID.
    func removeJob(id: String) async {
        guard let client = gatewayClient else { return }
        do {
            let _ = try await client.call("cron.manage", params: [
                "action": AnyCodable("remove"),
                "name": AnyCodable(id)
            ])
            await refreshJobs()
        } catch {
            NSLog("[CronListViewModel] Failed to remove job \(id): \(error)")
        }
    }
}
