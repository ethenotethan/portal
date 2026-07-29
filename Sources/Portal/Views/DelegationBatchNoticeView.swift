import SwiftUI

/// A centered interstitial notice for a gateway async-delegation batch marker
/// (e.g. `[ASYNC DELEGATION BATCH COMPLETE]`). These arrive as assistant message
/// content but are status notices, not model prose — so instead of pushing the
/// raw bracketed marker through the markdown bubble (which reads as a broken
/// response), the transcript shows this thin centered rule + caption, the same
/// visual weight as a system divider. Detected by
/// `ChatMessage.delegationBatchNoticeLabel`.
internal struct DelegationBatchNoticeView: View {
    /// Humanized label from `delegationBatchNoticeLabel` (e.g. "delegation
    /// batch complete").
    internal let label: String

    internal var body: some View {
        HStack(spacing: 10) {
            rule
            HStack(spacing: 5) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 11))
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.tertiary)
            .fixedSize()
            rule
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
