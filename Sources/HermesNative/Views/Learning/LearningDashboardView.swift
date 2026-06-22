import SwiftUI

/// Unified Learning Dashboard showing all saved quiz sessions and flashcard decks.
/// Accessible from the home page toolbar via a "Learning" (books) button.
/// Users can browse past quizzes, retake them, study flashcard decks,
/// and manage their learning library.
struct LearningDashboardView: View {
    @State private var quizzes: [PersistedQuizSession] = []
    @State private var decks: [FlashcardDeck] = []
    @State private var selectedTab: LearningTab = .quizzes

    let onClose: () -> Void
    let onStudyDeck: (FlashcardDeck) -> Void
    let onRetakeQuiz: ([QuizQuestion], String) -> Void

    enum LearningTab: String, CaseIterable {
        case quizzes = "Quizzes"
        case flashcards = "Flashcards"

        var icon: String {
            switch self {
            case .quizzes: return "questionmark.circle"
            case .flashcards: return "rectangle.on.rectangle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
                .padding(.horizontal, 20)
                .padding(.top, 16)

            // Tab picker
            tabPicker
                .padding(.horizontal, 20)
                .padding(.top, 12)

            Divider()
                .background(Theme.border)
                .padding(.top, 12)
                .padding(.horizontal, 20)

            // Content
            if activeItems.isEmpty {
                emptyState
            } else {
                contentList
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(Theme.background)
        #if os(macOS)
        .frame(
            width: min((NSScreen.main?.visibleFrame.width ?? 800) * 0.7, 700),
            height: min((NSScreen.main?.visibleFrame.height ?? 700) * 0.75, 560)
        )
        #endif
        .onAppear {
            refresh()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Learning")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .textCase(.uppercase)
                Text("Quizzes & Flashcards")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }

            Spacer()

            // Stats badge
            summaryBadge

            // Close button
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close learning dashboard")
        }
    }

    private var summaryBadge: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.caption2)
                Text("\(quizzes.count)")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Theme.accent)

            HStack(spacing: 4) {
                Image(systemName: "rectangle.on.rectangle.fill")
                    .font(.caption2)
                Text("\(decks.count)")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Theme.success)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(LearningTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selectedTab == tab ? Theme.primary : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == tab
                            ? Theme.surface
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.surfaceHover.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Content

    private var activeItems: [any Identifiable] {
        switch selectedTab {
        case .quizzes: return quizzes
        case .flashcards: return decks
        }
    }

    private var contentList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Summary stats
                sectionSummary
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                // Items
                ForEach(0..<activeItems.count, id: \.self) { index in
                    switch selectedTab {
                    case .quizzes:
                        quizRow(quizzes[index])
                    case .flashcards:
                        deckRow(decks[index])
                    }
                }

                // All-caught-up message
                if selectedTab == .flashcards, decks.allSatisfy({ $0.dueCount == 0 }), !decks.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("All caught up! No cards due.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var sectionSummary: some View {
        switch selectedTab {
        case .quizzes:
            if !quizzes.isEmpty {
                quizSummaryBar
            }
        case .flashcards:
            if !decks.isEmpty {
                flashcardSummaryBar
            }
        }
    }

    // MARK: - Quiz Summary

    private var quizSummaryBar: some View {
        HStack(spacing: 12) {
            summaryStat(
                value: "\(quizzes.count)",
                label: "Quizzes",
                color: Theme.accent
            )
            summaryStat(
                value: "\(quizzes.reduce(0) { $0 + $1.totalCount })",
                label: "Questions",
                color: Theme.primary
            )
            summaryStat(
                value: avgQuizScore,
                label: "Avg Score",
                color: avgScoreColor
            )
        }
    }

    private var avgQuizScore: String {
        guard !quizzes.isEmpty else { return "0%" }
        let avg = Double(quizzes.reduce(0) { $0 + $1.scorePercent }) / Double(quizzes.count)
        return "\(Int(round(avg)))%"
    }

    private var avgScoreColor: Color {
        guard !quizzes.isEmpty else { return Theme.secondary }
        let avg = Double(quizzes.reduce(0) { $0 + $1.scorePercent }) / Double(quizzes.count)
        if avg >= 80 { return Theme.success }
        if avg >= 50 { return Theme.warning }
        return .red
    }

    // MARK: - Flashcard Summary

    private var flashcardSummaryBar: some View {
        HStack(spacing: 12) {
            summaryStat(
                value: "\(decks.count)",
                label: "Decks",
                color: Theme.accent
            )
            summaryStat(
                value: "\(decks.reduce(0) { $0 + $1.totalCount })",
                label: "Cards",
                color: Theme.primary
            )
            summaryStat(
                value: "\(decks.reduce(0) { $0 + $1.learnedCount })",
                label: "Learned",
                color: Theme.success
            )
            summaryStat(
                value: "\(decks.reduce(0) { $0 + $1.dueCount })",
                label: "Due",
                color: totalDueCount > 0 ? Theme.warning : Theme.success
            )
        }
    }

    private var totalDueCount: Int {
        decks.reduce(0) { $0 + $1.dueCount }
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Quiz Row

    private func quizRow(_ quiz: PersistedQuizSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(quiz.topic)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        // Score badge
                        HStack(spacing: 4) {
                            Image(systemName: scoreIcon(quiz))
                                .font(.caption2)
                            Text(quiz.scoreLabel)
                                .font(.caption2)
                                .foregroundStyle(scoreColor(quiz))
                        }

                        // Questions count
                        Text("\(quiz.totalCount) questions")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)

                        // Date
                        Text(quiz.completedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer()

                // Retake button
                Button {
                    onRetakeQuiz(quiz.questions, quiz.topic)
                    onClose()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text("Retake")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border.opacity(0.5), lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                let id = quiz.id
                quizzes.removeAll { $0.id == id }
                QuizStore.shared.deleteQuiz(id: id)
            } label: {
                Label("Delete Quiz", systemImage: "trash")
            }
        }
    }

    private func scoreIcon(_ quiz: PersistedQuizSession) -> String {
        if quiz.scorePercent >= 80 { return "star.fill" }
        if quiz.scorePercent >= 50 { return "checkmark.circle.fill" }
        return "xmark.circle.fill"
    }

    private func scoreColor(_ quiz: PersistedQuizSession) -> Color {
        if quiz.scorePercent >= 80 { return Theme.success }
        if quiz.scorePercent >= 50 { return Theme.warning }
        return .red
    }

    // MARK: - Deck Row

    private func deckRow(_ deck: FlashcardDeck) -> some View {
        VStack(spacing: 0) {
            HStack {
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

                        HStack(spacing: 4) {
                            Image(systemName: "brain.head.profile")
                                .font(.caption2)
                            Text("\(deck.learnedCount)/\(deck.totalCount) learned")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                        }

                        Text(deck.created, style: .date)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer()

                if deck.dueCount > 0 {
                    Button {
                        onStudyDeck(deck)
                        onClose()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Study")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                        Text("Done")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.success.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(deck.dueCount > 0 ? Theme.warning.opacity(0.3) : Theme.border.opacity(0.5), lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                let id = deck.id
                decks.removeAll { $0.id == id }
                SRSStore.shared.deleteDeck(id: id)
            } label: {
                Label("Delete Deck", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: selectedTab == .quizzes ? "questionmark.folder" : "rectangle.stack.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiary)
            Text(selectedTab == .quizzes ? "No Quizzes Yet" : "No Flashcard Decks")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(selectedTab == .quizzes
                ? "Complete a quiz to save it here. Just ask the agent to quiz you on a topic."
                : "Generate flashcards by typing /flashcard <topic> in chat, or the agent can create them automatically.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Data

    private func refresh() {
        quizzes = QuizStore.shared.allQuizzes()
        decks = SRSStore.shared.allDecks()
    }
}

// MARK: - Preview

#if DEBUG
struct LearningDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        LearningDashboardView(
            onClose: {},
            onStudyDeck: { _ in },
            onRetakeQuiz: { _, _ in }
        )
        .background(Theme.background)
    }
}
#endif