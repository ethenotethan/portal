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

    init() {
        LeakTracker.track(self)
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
                // Auto-declare each job as a maintainer on any artifacts it wrote.
                for job in jobs {
                    Self.stampMaintainerForJob(job)
                }
            }
        }
    }

    /// Stamp `cron:<jobID>` onto any artifact whose `updatedBy` matches this
    /// job's name or id. Only touches artifacts that don't already list this
    /// job as a maintainer, so repeated polls are idempotent.
    private static func stampMaintainerForJob(_ job: CronJob) {
        let ref = MaintainerRef.cron(jobID: job.id)
        let artifactStore = ArtifactStore.shared
        for artifact in artifactStore.artifacts.values {
            let by = artifact.updatedBy
            guard by.contains(job.id) || by.contains(job.name) else { continue }
            guard !artifact.maintainerRefs.contains(ref) else { continue }
            artifactStore.setMaintainers(
                artifactID: artifact.id,
                refs: artifact.maintainerRefs + [ref]
            )
        }
    }

    deinit {
        // deinit is nonisolated even on a @MainActor class; Timer.invalidate()
        // is safe here because the repeating timer would otherwise retain its
        // closure (weak self, so no cycle) and keep firing forever.
        timer?.invalidate()
    }
}
