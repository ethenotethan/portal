import SwiftUI

/// Full flashcard study session view.
/// Cycles through cards in a deck, supports swipe, keyboard, and button navigation.
/// Tracks self-grades, applies SM-2 spaced repetition, and shows completion stats.
struct FlashcardDeckView: View {
    let deck: FlashcardDeck
    let onClose: () -> Void
    let onDeckUpdated: (FlashcardDeck) -> Void

    @State private var currentIndex: Int = 0
    @State private var updatedDeck: FlashcardDeck
    @State private var isComplete: Bool = false
    @State private var grades: [UUID: SRSQuality] = [:]
    @State private var dragOffset: CGFloat = 0

    init(deck: FlashcardDeck, onClose: @escaping () -> Void, onDeckUpdated: @escaping (FlashcardDeck) -> Void) {
        self.deck = deck
        self.onClose = onClose
        self.onDeckUpdated = onDeckUpdated
        self._updatedDeck = State(initialValue: deck)
    }

    private var dueCards: [Flashcard] {
        updatedDeck.dueCards
    }

    private var currentCard: Flashcard? {
        guard currentIndex < dueCards.count else { return nil }
        return dueCards[currentIndex]
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                flashcardHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                Divider()
                    .background(Theme.border)
                    .padding(.top, 12)
                    .padding(.horizontal, 20)

                if isComplete {
                    completionScreen
                } else if let card = currentCard {
                    // Card with swipe support
                    HStack(spacing: 0) {
                        // Prev button
                        navButton(direction: -1)

                        FlashcardView(
                            card: card,
                            cardIndex: currentIndex,
                            totalCount: dueCards.count,
                            onGrade: { quality in
                                handleGrade(card: card, quality: quality)
                            }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = value.translation.width
                                }
                                .onEnded { value in
                                    let threshold: CGFloat = 60
                                    if value.translation.width < -threshold {
                                        advanceCard()
                                    } else if value.translation.width > threshold {
                                        previousCard()
                                    }
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = 0
                                    }
                                }
                        )
                        .offset(x: dragOffset)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                        // Next button
                        navButton(direction: 1)
                    }
                    .padding(.horizontal, 8)
                } else {
                    emptyDeckScreen
                }

                Spacer(minLength: 0)
            }
            // ── Keyboard navigation (macOS) ──
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                previousCard()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                advanceCard()
                return .handled
            }
            .onKeyPress(.space) {
                // Space flips the card — handled inside FlashcardView via accessibility
                return .ignored
            }
        }
        .background(Theme.background)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        .frame(
            width: min((NSScreen.main?.visibleFrame.width ?? 800) * 0.7, 700),
            height: min((NSScreen.main?.visibleFrame.height ?? 700) * 0.8, 650)
        )
        #endif
    }

    // MARK: - Navigation buttons

    private func navButton(direction: Int) -> some View {
        let isFirst = direction == -1 && currentIndex == 0
        let isLast = direction == 1 && currentIndex >= dueCards.count - 1
        return Button {
            if direction == -1 { previousCard() }
            else { advanceCard() }
        } label: {
            Image(systemName: direction == -1 ? "chevron.left" : "chevron.right")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle((isFirst && direction == -1) || (isLast && direction == 1) ? Theme.tertiary.opacity(0.3) : Theme.secondary)
                .frame(width: 32, height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled((isFirst && direction == -1) || (isLast && direction == 1))
    }

    private func previousCard() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex -= 1
        }
    }

    private func advanceCard() {
        guard currentIndex + 1 < dueCards.count else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex += 1
        }
    }

    // MARK: - Header

    private var flashcardHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flashcards")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .textCase(.uppercase)
                    Text(updatedDeck.topic)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                }

                Spacer()

                // Stats badge
                HStack(spacing: 4) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text("\(updatedDeck.learnedCount)/\(updatedDeck.totalCount) learned")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())

                // Close button
                Button {
                    onDeckUpdated(updatedDeck)
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close flashcards")
            }

            // Progress bar
            if !isComplete {
                flashcardProgressBar
            }
        }
    }

    private var flashcardProgressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Card \(min(currentIndex + 1, dueCards.count))/\(dueCards.count)")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(updatedDeck.dueCount) due")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.surfaceHover)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                        .frame(
                            width: max(0, min(geo.size.width, geo.size.width * CGFloat(currentIndex) / CGFloat(max(1, dueCards.count)))),
                            height: 6
                        )
                        .animation(.easeInOut(duration: 0.3), value: currentIndex)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Grade Handling

    private func handleGrade(card: Flashcard, quality: SRSQuality) {
        grades[card.id] = quality

        // Apply SM-2
        let currentState = updatedDeck.srsStates[card.id] ?? SRSState(cardID: card.id)
        let newState = SRSEngine.calculate(quality: quality, state: currentState)
        updatedDeck.srsStates[card.id] = newState

        // Delay then advance to next card
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                if currentIndex + 1 < dueCards.count {
                    currentIndex += 1
                } else {
                    isComplete = true
                }
            }
        }
    }

    // MARK: - Empty Deck

    private var emptyDeckScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.success)
            Text("All caught up!")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text("No cards are due for review right now.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Spacer()
        }
    }

    // MARK: - Completion Screen

    private var completionScreen: some View {
        VStack(spacing: 20) {
            Spacer()

            // Stats summary
            VStack(spacing: 12) {
                Image(systemName: "party.popper.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)

                Text("Session Complete!")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.primary)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    statBox(
                        value: "\(grades.count)",
                        label: "Reviewed",
                        color: Theme.accent
                    )
                    statBox(
                        value: "\(updatedDeck.dueCount)",
                        label: "Still Due",
                        color: Theme.warning
                    )
                    statBox(
                        value: "\(updatedDeck.learnedCount)",
                        label: "Learned",
                        color: Theme.success
                    )
                }

                // Grade distribution
                VStack(alignment: .leading, spacing: 8) {
                    Text("Self-Grade Distribution")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .textCase(.uppercase)

                    ForEach(SRSQuality.allCases, id: \.rawValue) { quality in
                        let count = grades.values.filter { $0 == quality }.count
                        if count > 0 {
                            gradeDistributionRow(quality: quality, count: count)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 10) {
                if updatedDeck.dueCount > 0 {
                    Button {
                        // Restart with remaining due cards
                        currentIndex = 0
                        isComplete = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14))
                            Text("Review Remaining (\(updatedDeck.dueCount))")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onDeckUpdated(updatedDeck)
                    onClose()
                } label: {
                    Text("Done")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func statBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func gradeDistributionRow(quality: SRSQuality, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(quality.emoji)
                .font(.caption)
            Text(quality.label)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .frame(width: 80, alignment: .leading)
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FlashcardDeckView_Previews: PreviewProvider {
    static var previews: some View {
        FlashcardDeckView(
            deck: FlashcardDeck(
                topic: "Sample Deck",
                cards: [
                    Flashcard(front: "What is SwiftUI?", back: "Apple's declarative UI framework.", explanation: "Introduced at WWDC 2019.", category: "iOS"),
                    Flashcard(
                        front: "What is @State?",
                        back: "A property wrapper for local view state.",
                        explanation: "SwiftUI recreates the view when @State changes.",
                        category: "SwiftUI"
                    )
                ]
            ),
            onClose: {},
            onDeckUpdated: { _ in }
        )
        .background(Theme.background)
    }
}
#endif
