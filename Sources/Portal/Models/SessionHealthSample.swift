import Foundation

/// One reading of the process's health, taken every sampling interval by the
/// session health monitor and logged as a single `Health:` line. The fields are
/// the hypotheses for the long-session degradation the app has shown (artifact
/// scrolls and sessions going bad after hours of use): memory and thread growth,
/// main-thread hangs, a pending-request pool that stops draining, web views and
/// view models that outlive their screens, relayout churn.
///
/// `nil` means the metric could not be read on this host or build; the line
/// prints `n/a` for it rather than a made-up zero.
internal struct SessionHealthSample: Codable, Equatable, Sendable {
    internal var timestamp: Date
    internal var uptimeSeconds: Double

    // Process
    internal var footprintBytes: UInt64?
    internal var threadCount: Int?
    internal var fileDescriptors: Int?
    internal var cpuPercent: Double?

    // Main thread (MainThreadWatchdog)
    internal var hangCount: Int?
    internal var stormCount: Int?
    internal var longestHangMs: Int?

    // Gateway
    internal var gatewayState: String?
    internal var pendingRequests: Int?
    internal var reconnectAttempt: Int?
    internal var eventsSinceLast: Int?
    internal var lastRTTms: Int?

    // Live objects
    internal var chatViewModelsAlive: Int?
    internal var sessionsOpen: Int?
    internal var webViewsAlive: Int?
    internal var inlineHTMLViewsAlive: Int?
    internal var artifactCanvasesAlive: Int?
    internal var artifactsInMemory: Int?

    // Churn since the last sample
    internal var artifactRelayouts: Int?
    internal var webViewReloads: Int?
    internal var relayoutGuardTrips: Int?

    internal init(timestamp: Date, uptimeSeconds: Double) {
        self.timestamp = timestamp
        self.uptimeSeconds = uptimeSeconds
    }

    internal var footprintMB: Double? {
        footprintBytes.map { Double($0) / 1_048_576 }
    }

    /// The `Health:` log line: `key=value` pairs in a fixed order, so the file
    /// can be grepped and plotted. Numbers only, no units in values (the key
    /// names carry them), `n/a` for anything unreadable.
    internal func healthLine() -> String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
        func fixed(_ value: Double?, _ digits: Int = 0) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.\(digits)f", value)
        }
        let pairs: [(String, String)] = [
            ("uptime_s", fixed(uptimeSeconds)),
            ("mem_mb", fixed(footprintMB)),
            ("threads", number(threadCount)),
            ("fds", number(fileDescriptors)),
            ("cpu_pct", fixed(cpuPercent)),
            ("hangs", number(hangCount)),
            ("storms", number(stormCount)),
            ("longest_hang_ms", number(longestHangMs)),
            ("gateway", gatewayState ?? "n/a"),
            ("pending_rpc", number(pendingRequests)),
            ("reconnect_attempt", number(reconnectAttempt)),
            ("events", number(eventsSinceLast)),
            ("rtt_ms", number(lastRTTms)),
            ("chat_vms", number(chatViewModelsAlive)),
            ("sessions", number(sessionsOpen)),
            ("webviews", number(webViewsAlive)),
            ("inline_html", number(inlineHTMLViewsAlive)),
            ("artifact_canvases", number(artifactCanvasesAlive)),
            ("artifacts", number(artifactsInMemory)),
            ("artifact_relayouts", number(artifactRelayouts)),
            ("webview_reloads", number(webViewReloads)),
            ("relayout_guard_trips", number(relayoutGuardTrips)),
        ]
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
