import SwiftUI

// MARK: - Stat Tile

/// Compact stat tile for the Learning header strip.
/// Value wears a text token; a small colored icon carries any status meaning.
struct LearningStatTile: View {
    let value: String
    let label: String
    var icon: String?
    var iconColor: Color = Theme.secondary

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(iconColor)
                }
                Text(value)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Due Review Banner

/// Call-to-action shown when flashcards are due for review.
struct LearningDueBanner: View {
    let dueCount: Int
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.warning)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(dueCount) card\(dueCount == 1 ? "" : "s") due")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text("Keep your streak going")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Review now")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.accent, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.warning.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dueCount) cards due. Review now")
    }
}

// MARK: - Progress Ring

/// Small determinate ring used on quiz and deck cards.
struct LearningProgressRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 3.5
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceHover, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Quiz Card

/// Card row for a saved quiz session. The whole card opens the player.
struct LearningQuizCard: View {
    let quiz: PersistedQuizSession
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var scoreColor: Color {
        if quiz.scorePercent >= 80 { return Theme.success }
        if quiz.scorePercent >= 50 { return Theme.warning }
        return .red
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    LearningProgressRing(
                        fraction: Double(quiz.scorePercent) / 100,
                        color: scoreColor
                    )
                    Text("\(quiz.scorePercent)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.primary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(quiz.topic)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(quiz.scoreLabel)
                            .font(.caption2)
                            .foregroundStyle(scoreColor)
                        Text("\(quiz.totalCount) questions")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                        Text(quiz.completedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Retake")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onOpen) {
                Label("Retake Quiz", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Quiz", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(quiz.topic), scored \(quiz.scoreLabel). Retake quiz")
    }
}

// MARK: - Deck Card

/// Card row for a flashcard deck. The whole card opens the study player.
struct LearningDeckCard: View {
    let deck: FlashcardDeck
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var learnedFraction: Double {
        guard deck.totalCount > 0 else { return 0 }
        return Double(deck.learnedCount) / Double(deck.totalCount)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    LearningProgressRing(fraction: learnedFraction, color: Theme.accent)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.topic)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if deck.dueCount > 0 {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Theme.warning)
                                    .frame(width: 6, height: 6)
                                Text("\(deck.dueCount) due")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.warning)
                            }
                        }
                        Text("\(deck.learnedCount)/\(deck.totalCount) learned")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                        Text(deck.created, style: .date)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer(minLength: 8)

                if deck.dueCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Study")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Done")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.success)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        deck.dueCount > 0 ? Theme.warning.opacity(0.3) : Theme.border.opacity(0.5),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onOpen) {
                Label("Study Deck", systemImage: "play")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Deck", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(deck.topic), \(deck.dueCount) cards due, \(deck.learnedCount) of \(deck.totalCount) learned. Study deck")
    }
}

// MARK: - Empty State

/// Per-section empty state with a hint about how content is created.
struct LearningEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Preview

#if DEBUG
struct LearningComponents_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            LearningDueBanner(dueCount: 12, onReview: {})
            LearningEmptyState(
                icon: "questionmark.circle",
                title: "No quizzes yet",
                message: "Ask the agent to quiz you on any topic — finished quizzes are saved here."
            )
        }
        .padding()
        .background(Theme.background)
    }
}
#endif
