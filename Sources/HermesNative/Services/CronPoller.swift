import Foundation

/// Periodically polls the gateway for cron job state so notifications fire
/// even when the user hasn't opened the cron tab.  Dispatches new runs to
/// CronRunHistoryStore.detectNewRuns() every 60 seconds.
@MainActor
final class CronPoller: ObservableObject {
    private weak var client: GatewayClient?
    private var timer: Timer? {
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
}
