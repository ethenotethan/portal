import SwiftUI

/// A single flashcard with front/back sides and a 3D flip animation.
/// User taps to reveal the answer, then self-grades with quality buttons.
struct FlashcardView: View {
    let card: Flashcard
    let cardIndex: Int
    let totalCount: Int
    let onGrade: (SRSQuality) -> Void

    @State private var isFlipped = false
    @State private var hasGraded = false
    @Namespace private var flipNamespace

    var body: some View {
        VStack(spacing: 16) {
            // Progress
            progressView
                .padding(.horizontal, 20)

            // Card
            cardBody
                .padding(.horizontal, 20)

            Spacer(minLength: 12)

            // Action area
            if isFlipped && !hasGraded {
                gradeButtons
                    .padding(.horizontal, 20)
            } else if !isFlipped {
                tapPrompt
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        HStack {
            Text("Card \(cardIndex + 1)/\(totalCount)")
                .font(.caption)
                .foregroundStyle(Theme.secondary)

            Spacer()

            if let category = card.category {
                Text(category)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surfaceHover, in: Capsule())
            }
        }
    }

    // MARK: - Card Body

    private var cardBody: some View {
        ZStack {
            if isFlipped {
                backSide
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                frontSide
            }
        }
        .frame(minHeight: 220)
        .onTapGesture {
            guard !hasGraded else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                isFlipped.toggle()
            }
        }
    }

    // MARK: - Front Side (Question)

    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)

                Spacer()

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }

            Text(card.front)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !card.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(card.tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if card.tags.count > 4 {
                        Text("+\(card.tags.count - 4)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Back Side (Answer)

    private var backSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.success)

                Spacer()

                Text("Answer")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.back)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !card.explanation.isEmpty && card.explanation != card.back {
                        Divider()
                            .background(Theme.border)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Explanation")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondary)

                            Text(card.explanation)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.success.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Tap Prompt

    private var tapPrompt: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.caption)
            Text("Tap card to reveal answer")
                .font(.caption)
        }
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: - Grade Buttons

    private var gradeButtons: some View {
        VStack(spacing: 10) {
            Text("How well did you know it?")
                .font(.caption)
                .foregroundStyle(Theme.secondary)

            HStack(spacing: 10) {
                ForEach(SRSQuality.allCases, id: \.rawValue) { quality in
                    gradeButton(quality)
                }
            }
        }
    }

    private func gradeButton(_ quality: SRSQuality) -> some View {
        Button {
            guard !hasGraded else { return }
            hasGraded = true
            withAnimation(.easeOut(duration: 0.2)) {
                onGrade(quality)
            }
        } label: {
            VStack(spacing: 4) {
                Text(quality.emoji)
                    .font(.title2)
                Text(quality.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(gradeBgColor(quality), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(gradeBorderColor(quality), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func gradeBgColor(_ quality: SRSQuality) -> Color {
        switch quality {
        case .blackout: return Color.red.opacity(0.08)
        case .difficult: return Theme.warning.opacity(0.08)
        case .good: return Theme.success.opacity(0.08)
        case .perfect: return Theme.accent.opacity(0.08)
        }
    }

    private func gradeBorderColor(_ quality: SRSQuality) -> Color {
        switch quality {
        case .blackout: return Color.red.opacity(0.3)
        case .difficult: return Theme.warning.opacity(0.3)
        case .good: return Theme.success.opacity(0.3)
        case .perfect: return Theme.accent.opacity(0.3)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FlashcardView_Previews: PreviewProvider {
    static var previews: some View {
        FlashcardView(
            card: Flashcard(
                front: "What is the primary research domain of the Hermes Wiki?",
                back: "AI/ML research with a focus on local LLM inference and Apple Silicon optimization.",
                explanation: "The SCHEMA.md defines the domain as covering MLX, Metal kernels, speculative decoding, MoE architectures, and distributed inference.",
                category: "Wiki",
                tags: ["domain", "schema"]
            ),
            cardIndex: 0,
            totalCount: 5,
            onGrade: { _ in }
        )
        .frame(width: 500, height: 400)
        .background(Theme.background)
    }
}
#endif
