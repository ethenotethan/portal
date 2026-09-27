import SwiftUI

/// Settings surface for the session health watchdog: what the last sample
/// said, the sampling interval, a button that writes a diagnostic bundle now,
/// and where the last bundle went. Its own file, like the other sections,
/// because `SettingsView.swift` is over the file-length limit.
internal struct DiagnosticsSettingsSection: View {
    @ObservedObject private var status: SessionHealthStatus
    private let monitor: SessionHealthMonitor
    internal let showsHeader: Bool
    @State private var isCapturing = false

    internal init(showsHeader: Bool = true) {
        self.init(monitor: sessionHealthMonitor, showsHeader: showsHeader)
    }

    internal init(monitor: SessionHealthMonitor, showsHeader: Bool = true) {
        self.monitor = monitor
        self.status = monitor.status
        self.showsHeader = showsHeader
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                HStack(spacing: 10) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text("Diagnostics")
                        .font(.title2.weight(.semibold))
                }
            }

            Text("Portal samples its own health while it runs: memory, threads, main-thread hangs, the gateway's "
                 + "pending requests, and how many chat sessions and web views are alive. Each sample is one "
                 + "`Health:` line in the app log. When the numbers look like the long-session degradation "
                 + "(artifact scrolls and sessions going bad after hours of use), a diagnostic bundle is written "
                 + "automatically and you are told where it is.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Sample every", selection: intervalBinding) {
                ForEach(SessionHealthMonitor.allowedIntervals, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)

            if let latest = status.latest {
                latestSummary(latest)
            } else {
                Text("No sample yet — the first one lands within the interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Button(isCapturing ? "Capturing…" : "Capture Diagnostics Now") {
                    isCapturing = true
                    Task {
                        await capturePortalDiagnostics()
                        isCapturing = false
                    }
                }
                .portalButton(prominent: true, size: .small)
                .disabled(isCapturing)
                .help("Write a diagnostic bundle now: health samples, gateway snapshot, live objects, log tail, thread sample")
                if let bundle = status.lastBundle {
                    Text("Last bundle: \(bundle.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(bundle.path)
                }
            }
            if !status.lastFindings.isEmpty {
                Text(status.lastFindings.joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }
            Text("Bundles land in ~/Library/Logs/Portal/diagnostics/. Send the folder to whoever is diagnosing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { status.intervalSeconds },
            set: { monitor.setInterval(seconds: $0) }
        )
    }

    private func latestSummary(_ sample: SessionHealthSample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest sample")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Self.summary(sample))
                .font(.system(size: 11, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
        }
    }

    /// The handful of numbers a person reads first, from the full health line.
    internal static func summary(_ sample: SessionHealthSample) -> String {
        func show(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
        let memory = sample.footprintMB.map { String(format: "%.0f MB", $0) } ?? "n/a"
        return "memory \(memory) · threads \(show(sample.threadCount)) · hangs \(show(sample.hangCount))"
            + " · pending RPC \(show(sample.pendingRequests)) · chat VMs \(show(sample.chatViewModelsAlive))"
            + " · web views \(show(sample.webViewsAlive)) · uptime \(Int(sample.uptimeSeconds / 60)) min"
    }
}
