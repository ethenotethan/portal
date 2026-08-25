import SwiftUI

/// Renders a parsed `DelegationBatchMessage` as a stack of per-task cards
/// instead of the raw `[ASYNC DELEGATION BATCH COMPLETE — …]` wall of text.
///
/// The gateway re-injects a finished fan-out as one assistant message whose body
/// is a header, a preamble, and one `--- ✓ TASK n/m … ---` section per subagent.
/// Pushed through the markdown bubble it reads as an unformatted block; here each
/// subagent becomes a titled card with a status badge, its metadata as chips, and
/// its summary rendered as real markdown. Detected by
/// `ChatMessage.asyncDelegationBatch`.
internal struct AsyncDelegationBatchView: View {
    internal let batch: DelegationBatchMessage

    private var succeeded: Int { batch.tasks.filter(\.succeeded).count }
    private var failed: Int { batch.tasks.count - succeeded }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !batch.metaLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(batch.metaLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            ForEach(batch.tasks) { task in
                DelegationTaskCardView(task: task)
            }
            if let error = batch.batchError {
                batchErrorCard(error)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Delegation batch complete")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    /// e.g. "3 subagents · 2 ✓ · 1 ✗ · 6m 12s · deleg_72e3ab62".
    private var subtitle: String {
        var parts: [String] = ["\(batch.tasks.count) subagent\(batch.tasks.count == 1 ? "" : "s")"]
        if succeeded > 0 { parts.append("\(succeeded) ✓") }
        if failed > 0 { parts.append("\(failed) ✗") }
        if let dur = batch.totalDurationSeconds {
            parts.append(DelegationDuration.string(dur))
        }
        if let id = batch.delegationID { parts.append(id) }
        return parts.joined(separator: " · ")
    }

    private func batchErrorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.graphPatch)
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.graphPatch.opacity(0.12))
        )
    }
}

/// One subagent result — a collapsible card with a status badge, metadata chips,
/// and the summary body as markdown. Defaults to expanded so the results the
/// batch was dispatched for are readable at a glance; collapse to scan.
private struct DelegationTaskCardView: View {
    let task: DelegationBatchMessage.Task
    @State private var isExpanded = true

    private var accent: Color { task.succeeded ? Theme.success : Theme.graphPatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: { headerRow }
                .buttonStyle(.plain)

            if isExpanded {
                if !task.body.isEmpty {
                    MarkdownContentView(text: task.body)
                }
                if let truncation = task.truncation {
                    truncationNote(truncation)
                }
                if let transcript = task.liveTranscript {
                    footnote(icon: "doc.text.magnifyingglass", text: "Full transcript: \(transcript)")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.background.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: task.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 13))
                .foregroundStyle(accent)
            Text("Task \(task.index)/\(task.total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            if let goal = task.goal {
                Text(goal)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(isExpanded ? 2 : 1)
            }
            Spacer(minLength: 4)
            metaChips
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metaChips: some View {
        if !task.succeeded {
            chip(task.status, tint: Theme.graphPatch)
        }
        if let calls = task.apiCalls {
            chip("\(calls) call\(calls == 1 ? "" : "s")", tint: Theme.tertiary)
        }
        if let dur = task.durationSeconds {
            chip(DelegationDuration.string(dur), tint: Theme.tertiary)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            // `.monospaced()` re-asserts at the view level: the app-wide
            // `.fontDesign` applied at the root overrides a `design:` written
            // inside `.font(...)`, so these counts and durations would silently
            // lose their fixed-width digits the moment the user picks Serif.
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospaced()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func truncationNote(_ truncation: DelegationBatchMessage.Truncation) -> some View {
        footnote(icon: "scissors", text: truncationText(truncation))
    }

    private func truncationText(_ truncation: DelegationBatchMessage.Truncation) -> String {
        var text = "Summary truncated"
        if let total = truncation.totalChars {
            text += " — \(total.formatted()) chars total"
        }
        if let path = truncation.spillPath {
            text += "; full output at \(path)"
        }
        return text
    }

    private func footnote(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.caption2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.tertiary)
    }
}

/// Shared, compact seconds formatter for batch/task durations: "6m 12s" past a
/// minute, otherwise the raw "184.6s" the gateway reports.
internal enum DelegationDuration {
    internal static func string(_ seconds: Double) -> String {
        guard seconds >= 60 else {
            // Drop a trailing ".0" so whole seconds read cleanly.
            return seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
        }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }
}
