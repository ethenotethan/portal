import SwiftUI

/// Unified Learning dashboard: saved quiz sessions and flashcard decks.
/// iOS: a tab with NavigationStack — tapping a card pushes the player.
/// macOS: a full-bleed overlay pane (ContentView provides the Back chrome);
/// the player opens in a single sheet, matching ChatView's quiz presentation.
struct LearningDashboardView: View {
    @State private var quizzes: [PersistedQuizSession] = []
    @State private var decks: [FlashcardDeck] = []
    @State private var section: LearningSection = .quizzes

    /// Player state — quizzes and decks play from here, not through chat.
    @State private var quizVM = QuizViewModel()
    @State private var showPlayer = false
    @State private var pendingDelete: LearningDeleteTarget?

    /// Kept for entry-point compatibility; macOS overlay chrome and the iOS
    /// tab bar own dismissal, so no internal close button is rendered.
    let onClose: () -> Void
    /// Optional hook to continue review in a chat session ("Review with
    /// Agent"). When nil, that affordance is hidden.
    var onReviewWithAgent: ((String) -> Void)?

    enum LearningSection: String, CaseIterable {
        case quizzes = "Quizzes"
        case flashcards = "Flashcards"
    }

    private struct LearningDeleteTarget: Identifiable {
        enum Kind { case quiz, deck }
        let id: UUID
        let kind: Kind
        let title: String
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            dashboard
                .navigationTitle("Learning")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: $showPlayer) {
                    player
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        #else
        dashboard
            .sheet(isPresented: $showPlayer, onDismiss: refresh) {
                player
            }
        #endif
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(LearningSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 12) {
                    if totalDueCount > 0 {
                        LearningDueBanner(dueCount: totalDueCount, onReview: reviewDueCards)
                    }

                    switch section {
                    case .quizzes: quizSection
                    case .flashcards: flashcardSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .refreshable { refresh() }
            #endif
        }
        .background(Theme.background)
        .onAppear { refresh() }
        .onChange(of: showPlayer) { _, isShowing in
            if !isShowing { refresh() }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Player

    private var player: some View {
        QuizSheet(
            viewModel: quizVM,
            onClose: { showPlayer = false },
            onReviewWithAgent: { prompt in
                showPlayer = false
                onReviewWithAgent?(prompt)
            },
            onOpenLearning: { showPlayer = false }
        )
    }

    private func startQuiz(_ quiz: PersistedQuizSession) {
        quizVM.load(questions: quiz.questions, topic: quiz.topic)
        showPlayer = true
    }

    private func studyDeck(_ deck: FlashcardDeck) {
        quizVM.load(deck: deck)
        showPlayer = true
    }

    private func reviewDueCards() {
        guard let deck = sortedDecks.first(where: { $0.dueCount > 0 }) else { return }
        section = .flashcards
        studyDeck(deck)
    }

    // MARK: - Quizzes Section

    @ViewBuilder
    private var quizSection: some View {
        if quizzes.isEmpty {
            LearningEmptyState(
                icon: "questionmark.circle",
                title: "No Quizzes Yet",
                message: "Ask the agent to quiz you on any topic — finished quizzes are saved here to retake."
            )
        } else {
            HStack(spacing: 10) {
                LearningStatTile(value: "\(quizzes.count)", label: "Quizzes")
                LearningStatTile(
                    value: "\(quizzes.reduce(0) { $0 + $1.totalCount })",
                    label: "Questions"
                )
                LearningStatTile(
                    value: avgQuizScore,
                    label: "Avg Score",
                    icon: "chart.line.uptrend.xyaxis",
                    iconColor: avgScoreColor
                )
            }

            LazyVStack(spacing: 10) {
                ForEach(quizzes) { quiz in
                    LearningQuizCard(
                        quiz: quiz,
                        onOpen: { startQuiz(quiz) },
                        onDelete: {
                            pendingDelete = LearningDeleteTarget(id: quiz.id, kind: .quiz, title: quiz.topic)
                        }
                    )
                }
            }
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

    // MARK: - Flashcards Section

    @ViewBuilder
    private var flashcardSection: some View {
        if decks.isEmpty {
            LearningEmptyState(
                icon: "rectangle.on.rectangle",
                title: "No Flashcard Decks",
                message: "Type /flashcard <topic> in chat, or ask the agent — decks land here for spaced review."
            )
        } else {
            HStack(spacing: 10) {
                LearningStatTile(value: "\(decks.count)", label: "Decks")
                LearningStatTile(
                    value: "\(decks.reduce(0) { $0 + $1.totalCount })",
                    label: "Cards"
                )
                LearningStatTile(
                    value: "\(decks.reduce(0) { $0 + $1.learnedCount })",
                    label: "Learned",
                    icon: "brain.head.profile",
                    iconColor: Theme.success
                )
                LearningStatTile(
                    value: "\(totalDueCount)",
                    label: "Due",
                    icon: totalDueCount > 0 ? "clock" : "checkmark.circle",
                    iconColor: totalDueCount > 0 ? Theme.warning : Theme.success
                )
            }

            LazyVStack(spacing: 10) {
                ForEach(sortedDecks) { deck in
                    LearningDeckCard(
                        deck: deck,
                        onOpen: { studyDeck(deck) },
                        onDelete: {
                            pendingDelete = LearningDeleteTarget(id: deck.id, kind: .deck, title: deck.topic)
                        }
                    )
                }
            }

            if totalDueCount == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    Text("All caught up! No cards due.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private var sortedDecks: [FlashcardDeck] {
        decks.sorted { a, b in
            if (a.dueCount > 0) != (b.dueCount > 0) { return a.dueCount > 0 }
            return a.created > b.created
        }
    }

    private var totalDueCount: Int {
        decks.reduce(0) { $0 + $1.dueCount }
    }

    // MARK: - Data

    private func refresh() {
        quizzes = QuizStore.shared.allQuizzes()
        decks = SRSStore.shared.allDecks()
    }

    private func confirmDelete() {
        guard let target = pendingDelete else { return }
        switch target.kind {
        case .quiz:
            quizzes.removeAll { $0.id == target.id }
            QuizStore.shared.deleteQuiz(id: target.id)
        case .deck:
            decks.removeAll { $0.id == target.id }
            SRSStore.shared.deleteDeck(id: target.id)
        }
        pendingDelete = nil
    }
}

// MARK: - Preview

#if DEBUG
struct LearningDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        LearningDashboardView(onClose: {})
            .background(Theme.background)
    }
}
#endif
