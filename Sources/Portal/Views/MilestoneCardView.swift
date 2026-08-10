import SwiftUI

/// The milestone level and message the manager already computes, finally shown.
///
/// `.milestone(level:message:)` events existed from the start — "Skill unlocked:
/// X", "20 messages in this session!" — but the presentation site tested the
/// event for nil and then rendered confetti, so the payload was always dropped.
internal struct MilestoneCardView: View {
    internal let beat: CelebrationBeat
    internal let badge: String?
    internal let message: String

    internal var body: some View {
        HStack(spacing: 12) {
            Text(badge ?? "✨")
                .font(.system(size: 30))
                .rotationEffect(.degrees(beat.isShaking ? 8 : 0))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nice work")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                Text(message)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                        .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        )
        .frame(maxWidth: 360)
        .offset(y: beat.verticalOffsetFraction * 160)
        .opacity(beat == .offstage ? 0 : 1)
        .scaleEffect(beat.isAiming ? 1.04 : 1.0)
    }
}
