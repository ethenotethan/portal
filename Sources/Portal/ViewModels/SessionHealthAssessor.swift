import Foundation

/// Decides, from the recent health samples, whether the process is in the
/// degraded state the app has shown after long sessions. Pure: samples in,
/// findings out, so every rule is unit-tested on synthetic series. Each finding
/// names the rule and quotes the numbers, and the monitor writes a diagnostic
/// bundle when any fires.
internal enum SessionHealthAssessor {
    internal struct Finding: Equatable, Sendable, CustomStringConvertible {
        internal let rule: String
        internal let reason: String

        internal var description: String { "\(rule): \(reason)" }
    }

    /// Every threshold in one place. Each is a judgment about *this* app on a
    /// developer's Mac, not a universal truth; adjust with evidence from bundles.
    internal enum Thresholds {
        /// Absolute memory ceiling. A chat + artifacts + web views client that
        /// crosses 2 GiB is leaking something; the beachball follows.
        internal static let footprintBytes: UInt64 = 2 * 1024 * 1024 * 1024
        /// Relative growth that counts as a leak even below the ceiling.
        internal static let footprintGrowthFraction = 0.60
        /// …measured over this window…
        internal static let footprintGrowthWindow: TimeInterval = 30 * 60
        /// …between samples at least this far apart.
        internal static let footprintGrowthMinimumSpan: TimeInterval = 10 * 60
        /// No rule fires before this much uptime: a cold process at 9 MB "grows"
        /// 60× while it loads, and resuming a thousand sessions hangs the main
        /// thread on purpose. Launch is not the long-session state.
        internal static let warmUpSeconds: TimeInterval = 2 * 60
        /// Main-thread hangs (>250 ms turns) tolerated in the hang window.
        internal static let hangsInWindow = 3
        internal static let hangWindow: TimeInterval = 5 * 60
        /// A pending pool this deep for two consecutive samples is not draining.
        internal static let pendingRequests = 25
        /// More live web views than a screen can show means they are not released.
        internal static let webViewsAlive = 10
        /// …or they grow every sample for this many samples.
        internal static let webViewMonotonicSamples = 10
        /// Chat view models beyond the open sessions plus the page docks.
        internal static let chatViewModelSlack = 2
        /// Threads: SwiftUI + WebKit + URLSession idle around 40–70.
        internal static let threadCount = 150
        /// Undelivered gateway events queued client-side.
        internal static let eventBacklog = 500
        /// Open descriptors; the soft limit on macOS is typically 256–10240.
        internal static let fileDescriptors = 900
    }

    /// `samples` oldest first; `now` is the assessment time (injected for tests).
    /// Nothing fires during the warm-up: a launch that resumes a thousand
    /// sessions hangs and balloons on purpose, and the first bundle of a run
    /// must not be spent on it. The samples are still logged.
    internal static func assess(_ samples: [SessionHealthSample], now: Date) -> [Finding] {
        guard let latest = samples.last, latest.uptimeSeconds >= Thresholds.warmUpSeconds else { return [] }
        var findings: [Finding] = []

        if let bytes = latest.footprintBytes {
            if bytes > Thresholds.footprintBytes {
                findings.append(Finding(
                    rule: "memory-ceiling",
                    reason: "footprint \(megabytes(bytes)) MB exceeds \(megabytes(Thresholds.footprintBytes)) MB"
                ))
            }
            let windowStart = now.addingTimeInterval(-Thresholds.footprintGrowthWindow)
            if let earliest = samples.first(where: {
                   $0.timestamp >= windowStart && $0.footprintBytes != nil && $0.uptimeSeconds >= Thresholds.warmUpSeconds
               }),
               latest.timestamp.timeIntervalSince(earliest.timestamp) >= Thresholds.footprintGrowthMinimumSpan,
               let before = earliest.footprintBytes, before > 0 {
                let growth = Double(bytes) / Double(before) - 1
                if growth > Thresholds.footprintGrowthFraction {
                    let minutes = Int(latest.timestamp.timeIntervalSince(earliest.timestamp) / 60)
                    findings.append(Finding(
                        rule: "memory-growth",
                        reason: "footprint grew \(Int(growth * 100))% in \(minutes) min (\(megabytes(before)) → \(megabytes(bytes)) MB)"
                    ))
                }
            }
        }

        if let hangs = latest.hangCount {
            let windowStart = now.addingTimeInterval(-Thresholds.hangWindow)
            let baseline = samples.last(where: { $0.timestamp < windowStart && $0.hangCount != nil })?.hangCount ?? 0
            let recent = hangs - baseline
            if recent >= Thresholds.hangsInWindow {
                findings.append(Finding(
                    rule: "main-thread-hangs",
                    reason: "\(recent) hangs in the last \(Int(Thresholds.hangWindow / 60)) min (longest \(latest.longestHangMs ?? 0) ms)"
                ))
            }
        }

        if samples.count >= 2,
           let last = latest.pendingRequests,
           let previous = samples[samples.count - 2].pendingRequests,
           last >= Thresholds.pendingRequests, previous >= Thresholds.pendingRequests {
            findings.append(Finding(
                rule: "pending-rpc-pool",
                reason: "\(last) pending requests for two consecutive samples (gateway \(latest.gatewayState ?? "n/a"))"
            ))
        }

        if let webViews = latest.webViewsAlive {
            if webViews > Thresholds.webViewsAlive {
                findings.append(Finding(rule: "webviews-alive", reason: "\(webViews) WKWebViews alive"))
            } else {
                let recent = samples.suffix(Thresholds.webViewMonotonicSamples).compactMap(\.webViewsAlive)
                if isMonotonicallyGrowing(recent, minimumCount: Thresholds.webViewMonotonicSamples) {
                    findings.append(Finding(
                        rule: "webviews-growing",
                        reason: "WKWebView count grew every sample for \(Thresholds.webViewMonotonicSamples) samples (now \(webViews))"
                    ))
                }
            }
        }

        if let chatViewModels = latest.chatViewModelsAlive, let sessions = latest.sessionsOpen,
           chatViewModels > sessions + Thresholds.chatViewModelSlack {
            findings.append(Finding(rule: "chat-viewmodel-leak", reason: "\(chatViewModels) ChatViewModels alive for \(sessions) open sessions"))
        }

        if let threads = latest.threadCount, threads > Thresholds.threadCount {
            findings.append(Finding(rule: "thread-count", reason: "\(threads) threads"))
        }

        if let events = latest.eventsSinceLast, events > Thresholds.eventBacklog {
            findings.append(Finding(rule: "event-backlog", reason: "\(events) gateway events in one interval"))
        }

        if let fds = latest.fileDescriptors, fds > Thresholds.fileDescriptors {
            findings.append(Finding(rule: "file-descriptors", reason: "\(fds) open descriptors"))
        }

        return findings
    }

    /// Strictly increasing across at least `minimumCount` values.
    internal static func isMonotonicallyGrowing(_ values: [Int], minimumCount: Int) -> Bool {
        guard values.count >= minimumCount, values.count >= 2 else { return false }
        return zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    private static func megabytes(_ bytes: UInt64) -> Int {
        Int(bytes / 1_048_576)
    }
}

/// One bundle per `minimumInterval`, however often the assessor fires: the
/// state persists, and a folder per sample would bury the first, most useful one.
internal struct DiagnosticBundleRateLimiter: Sendable {
    internal let minimumInterval: TimeInterval
    internal private(set) var lastWrite: Date?

    internal init(minimumInterval: TimeInterval = 10 * 60) {
        self.minimumInterval = minimumInterval
    }

    /// Whether a bundle may be written now; records the write when it may.
    internal mutating func allow(now: Date) -> Bool {
        if let lastWrite, now.timeIntervalSince(lastWrite) < minimumInterval { return false }
        lastWrite = now
        return true
    }
}
