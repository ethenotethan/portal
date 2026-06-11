import Foundation

/// Periodically polls the gateway for cron job state so notifications fire
/// even when the user hasn't opened the cron tab.  Dispatches new runs to
/// CronRunHistoryStore.detectNewRuns() every 60 seconds.
@MainActor
final class CronPoller: ObservableObject {
    private weak var client: GatewayClient?
    // nonisolated(unsafe) so the nonisolated deinit can invalidate it.
    // All reads/writes happen on the MainActor; deinit runs after the last
    // (MainActor-held) reference is released.
    nonisolated(unsafe) private var timer: Timer? {
        didSet { oldValue?.invalidate() }
    }

    func setGatewayClient(_ client: GatewayClient) {
        guard self.client !== client else { return }
        self.client = client
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let client = self.client else { return }
                guard case .connected = client.connectionState else { return }
                guard let jobs = try? await client.listCronJobs() else { return }
                CronRunHistoryStore.shared.detectNewRuns(from: jobs)
            }
        }
    }

    deinit {
        // deinit is nonisolated even on a @MainActor class; Timer.invalidate()
        // is safe here because the repeating timer would otherwise retain its
        // closure (weak self, so no cycle) and keep firing forever.
        timer?.invalidate()
    }
}
