import SwiftUI

/// Why the last cron move/rename failed, shown under the Cron page's search bar.
///
/// Moving a job is fire-and-forget from a row context menu — there's no sheet to
/// hold an inline error and no button left on screen to turn red. Without this the
/// failure was logged and dropped, which is indistinguishable from success: the
/// list refreshes unchanged and the job sits where it started. "The feature is
/// broken" and "the write was rejected" have very different fixes, so the
/// difference has to reach the user.
///
/// Dismissible because it describes a past attempt, not current state.
internal struct CronMoveErrorBanner: View {
    internal let message: String
    internal let onDismiss: () -> Void

    internal var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            // Selectable: a version-skew message is something the user may want to
            // paste into an issue against the harness.
            Text(message)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}
