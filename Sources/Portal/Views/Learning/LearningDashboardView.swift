import SwiftUI

/// Unified Learning dashboard: structured courses, saved quiz sessions, and
/// flashcard decks.
/// iOS: a tab with NavigationStack — tapping a card pushes the player.
/// macOS: a full-bleed overlay pane (ContentView provides the Back chrome);
/// the player opens in a single sheet, matching ChatView's quiz presentation.
struct LearningDashboardView: View {
    @State private var quizzes: [PersistedQuizSession] = []
    @State private var decks: [FlashcardDeck] = []
    @State private var curricula: [Curriculum] = []
    @State private var section: LearningSection = .courses

    /// Player state — quizzes and decks play from here, not through chat.
    @State private var quizVM = QuizViewModel()
    @State private var showPlayer = false
    /// The open course. Presented full-bleed rather than through `quizVM`: a
    /// curriculum owns its own step navigation and progress writes, which
    /// `QuizViewModel`'s save-and-clear lifecycle can't express.
    @State private var activeCurriculum: Curriculum?
    @State private var pendingDelete: LearningDeleteTarget?

    /// Kept for entry-point compatibility; macOS overlay chrome and the iOS
    /// tab bar own dismissal, so no internal close button is rendered.
    let onClose: () -> Void
    /// Optional hook to continue review in a chat session ("Review with
    /// Agent"). When nil, that affordance is hidden.
    var onReviewWithAgent: ((String) -> Void)?
    /// When set, that course opens straight away instead of the dashboard —
    /// used when the agent has just generated one, so the user lands in the
    /// course rather than hunting for it in a list.
    internal var openCurriculumID: UUID?

    /// Course persistence. Held for the view's lifetime so directory setup runs
    /// once, and handed to the player so both read and write the same store.
    @State private var curriculumStore = CurriculumStore()

    enum LearningSection: String, CaseIterable {
        case courses = "Courses"
        case quizzes = "Quizzes"
        case flashcards = "Flashcards"

        internal var icon: String {
            switch self {
            case .courses: return "books.vertical"
            case .quizzes: return "questionmark.circle"
            case .flashcards: return "rectangle.on.rectangle"
            }
        }
    }

    private struct LearningDeleteTarget: Identifiable {
        enum Kind { case quiz, deck, curriculum }
        let id: UUID
        let kind: Kind
        let title: String
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            root
                .navigationTitle("Learning")
                .navigationBarTitleDisplayMode(.inline)
                // The course player brings its own header and back affordance,
                // so the nav bar would just duplicate the title.
                .toolbar(activeCurriculum == nil ? .visible : .hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showPlayer) {
                    player
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        #else
        root
            .sheet(isPresented: $showPlayer, onDismiss: refresh) {
                player
            }
        #endif
    }

    /// A course takes over the whole pane rather than opening in a sheet — it's
    /// a multi-step session, not a modal task, and swapping content in place
    /// avoids dismiss/re-present races between steps.
    @ViewBuilder
    private var root: some View {
        if let course = activeCurriculum {
            CurriculumPlayerView(
                curriculum: course,
                store: curriculumStore,
                onClose: {
                    activeCurriculum = nil
                    refresh()
                },
                onReviewWithAgent: onReviewWithAgent.map { handler in
                    { prompt in
                        activeCurriculum = nil
                        handler(prompt)
                    }
                }
            )
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            // Themed capsule control, matching the rest of the app's chrome —
            // not the stock segmented picker, which ignores the palette.
            ThemedSegmentedControl(
                selection: $section,
                options: LearningSection.allCases,
                label: { $0.rawValue },
                icon: { $0.icon }
            )
            .frame(maxWidth: 460)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 12) {
                    if totalDueCount > 0 {
                        LearningDueBanner(dueCount: totalDueCount, onReview: reviewDueCards)
                    }

                    switch section {
                    case .courses: courseSection
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
        .onAppear {
            refresh()
            openRequestedCurriculum()
        }
        .onChange(of: openCurriculumID) { _, _ in
            // The pane can already be open when a second course arrives, so
            // react to the id changing as well as to first appearance.
            refresh()
            openRequestedCurriculum()
        }
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

    // MARK: - Courses Section

    @ViewBuilder
    private var courseSection: some View {
        if curricula.isEmpty {
            LearningEmptyState(
                icon: "books.vertical",
                title: "No Courses Yet",
                message: "Type /curriculum <topic> in chat, or ask the agent to build you a course — "
                    + "lessons and quizzes land here with progress tracked per step."
            )
        } else {
            HStack(spacing: 10) {
                LearningStatTile(value: "\(curricula.count)", label: "Courses")
                LearningStatTile(
                    value: "\(curricula.reduce(0) { $0 + $1.totalSteps })",
                    label: "Steps"
                )
                LearningStatTile(
                    value: "\(curricula.reduce(0) { $0 + $1.completedCount })",
                    label: "Done",
                    icon: "checkmark.circle",
                    iconColor: Theme.success
                )
                LearningStatTile(
                    value: "\(curricula.filter(\.isFinished).count)",
                    label: "Finished",
                    icon: "checkmark.seal",
                    iconColor: curricula.contains(where: \.isFinished) ? Theme.success : Theme.secondary
                )
            }

            LazyVStack(spacing: 10) {
                ForEach(curricula) { course in
                    CurriculumCard(
                        curriculum: course,
                        onOpen: { activeCurriculum = course },
                        onDelete: {
                            pendingDelete = LearningDeleteTarget(
                                id: course.id,
                                kind: .curriculum,
                                title: course.title
                            )
                        }
                    )
                }
            }
        }
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
        curricula = curriculumStore.allCurricula()
    }

    /// Open the course named by `openCurriculumID`, if it's on disk. Reads from
    /// the store rather than the in-memory list so ordering and refresh timing
    /// can't make a just-saved course unreachable.
    private func openRequestedCurriculum() {
        guard let openCurriculumID,
              activeCurriculum?.id != openCurriculumID,
              let course = curriculumStore.load(id: openCurriculumID) else { return }
        section = .courses
        activeCurriculum = course
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
        case .curriculum:
            curricula.removeAll { $0.id == target.id }
            curriculumStore.delete(id: target.id)
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
