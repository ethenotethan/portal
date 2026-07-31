import SwiftUI

/// Course row on the Learning page. Mirrors `LearningQuizCard` /
/// `LearningDeckCard`: whole card opens, ring shows progress, context menu
/// carries the destructive action.
internal struct CurriculumCard: View {
    internal let curriculum: Curriculum
    internal let onOpen: () -> Void
    internal let onDelete: () -> Void

    private var ringColor: Color {
        curriculum.isFinished ? Theme.success : Theme.accent
    }

    internal var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    LearningProgressRing(
                        fraction: curriculum.progressFraction,
                        color: ringColor
                    )
                    if curriculum.isFinished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.success)
                    } else {
                        Text("\(Int(round(curriculum.progressFraction * 100)))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.primary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(curriculum.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("\(curriculum.completedCount)/\(curriculum.totalSteps) steps")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                        Text("\(curriculum.modules.count) module\(curriculum.modules.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                        if let average = curriculum.averageQuizScore {
                            Text("\(average)% avg")
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }

                Spacer(minLength: 8)

                if curriculum.isFinished {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Complete")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.success)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(curriculum.completedCount == 0 ? "Start" : "Continue")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        curriculum.isFinished
                            ? Theme.success.opacity(0.3)
                            : Theme.border.opacity(0.5),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onOpen) {
                Label(curriculum.completedCount == 0 ? "Start Course" : "Continue Course", systemImage: "play")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Course", systemImage: "trash")
            }
        }
        .accessibilityLabel(
            "\(curriculum.title), \(curriculum.completedCount) of \(curriculum.totalSteps) steps complete"
        )
    }
}

// MARK: - Step Row

/// One step inside the course outline: type icon, title, and its status.
internal struct CurriculumStepRow: View {
    internal let step: CurriculumStep
    internal let isComplete: Bool
    internal let needsRetry: Bool
    internal let bestScorePercent: Int?
    internal let isNext: Bool
    internal let onOpen: () -> Void

    private var statusIcon: String {
        if isComplete { return "checkmark.circle.fill" }
        if needsRetry { return "exclamationmark.circle.fill" }
        return "circle"
    }

    private var statusColor: Color {
        if isComplete { return Theme.success }
        if needsRetry { return Theme.warning }
        return Theme.tertiary
    }

    internal var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
                    .frame(width: 16)

                Image(systemName: step.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 13, weight: isNext ? .semibold : .regular))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(step.kindLabel)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                        if let bestScorePercent {
                            Text("best \(bestScorePercent)%")
                                .font(.caption2)
                                .foregroundStyle(isComplete ? Theme.success : Theme.warning)
                        }
                    }
                }

                Spacer(minLength: 4)

                if isNext {
                    Text("Next")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isNext ? Theme.accent.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.title), \(step.kindLabel), \(isComplete ? "complete" : "not complete")")
    }
}
