import SwiftUI

/// The course player: an outline of modules and steps, and — once a step is
/// opened — that step's lesson or quiz, in place.
///
/// One view with three states rather than three presented sheets, because
/// step-to-step advance is the core interaction; dismissing and re-presenting a
/// sheet per step would flicker and, on macOS, race the presentation.
internal struct CurriculumPlayerView: View {
    @State private var viewModel: CurriculumViewModel
    internal let onClose: () -> Void
    /// Sends a quiz-review prompt to chat. Hidden when nil.
    internal var onReviewWithAgent: ((String) -> Void)?

    internal init(
        curriculum: Curriculum,
        store: CurriculumStore,
        onClose: @escaping () -> Void,
        onReviewWithAgent: ((String) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: CurriculumViewModel(curriculum: curriculum, store: store))
        self.onClose = onClose
        self.onReviewWithAgent = onReviewWithAgent
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border.opacity(0.5))

            if let step = viewModel.activeStep {
                stepContent(step)
            } else {
                outline
            }
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    // Inside a step, back returns to the outline; from the
                    // outline it leaves the course.
                    if viewModel.activeStep == nil {
                        onClose()
                    } else {
                        viewModel.closeStep()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 26, height: 26)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.activeStep == nil ? "Back to Learning" : "Back to course outline")

                VStack(alignment: .leading, spacing: 1) {
                    Text(headerEyebrow)
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                        .textCase(.uppercase)
                    Text(headerTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(viewModel.curriculum.completedCount)/\(viewModel.curriculum.totalSteps)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: Capsule())
            }

            courseProgressBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var headerEyebrow: String {
        guard let step = viewModel.activeStep else { return "Course" }
        if let position = viewModel.activeStepPosition {
            return "Step \(position) of \(viewModel.curriculum.totalSteps)"
        }
        return step.isQuiz ? "Quiz" : "Lesson"
    }

    private var headerTitle: String {
        viewModel.activeStep?.title ?? viewModel.curriculum.title
    }

    private var courseProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.surfaceHover)
                Capsule()
                    .fill(viewModel.curriculum.isFinished ? Theme.success : Theme.accent)
                    .frame(width: geo.size.width * viewModel.curriculum.progressFraction)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Outline

    private var outline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !viewModel.curriculum.summary.isEmpty {
                    Text(viewModel.curriculum.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let next = viewModel.curriculum.nextStep {
                    continueBanner(next)
                } else {
                    courseCompleteBanner
                }

                ForEach(viewModel.curriculum.modules) { module in
                    moduleSection(module)
                }

                if viewModel.curriculum.completedCount > 0 {
                    Button {
                        viewModel.restartCourse()
                    } label: {
                        Label("Restart course", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private func continueBanner(_ step: CurriculumStep) -> some View {
        Button {
            viewModel.open(step)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: step.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.curriculum.completedCount == 0 ? "Start here" : "Pick up where you left off")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                    Text(step.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(viewModel.curriculum.completedCount == 0 ? "Start" : "Continue")
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
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.accent.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var courseCompleteBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("Course complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if let average = viewModel.curriculum.averageQuizScore {
                    Text("Average quiz score \(average)%")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.success.opacity(0.25), lineWidth: 1)
        )
    }

    private func moduleSection(_ module: CurriculumModule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(module.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(viewModel.curriculum.completedCount(in: module))/\(module.steps.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }

            if !module.overview.isEmpty {
                Text(module.overview)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 2) {
                ForEach(module.steps) { step in
                    CurriculumStepRow(
                        step: step,
                        isComplete: viewModel.curriculum.isComplete(step),
                        needsRetry: viewModel.curriculum.needsRetry(step),
                        bestScorePercent: viewModel.curriculum.progress(for: step)?.bestScorePercent,
                        isNext: viewModel.curriculum.nextStep?.id == step.id,
                        onOpen: { viewModel.open(step) }
                    )
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Step content

    @ViewBuilder
    private func stepContent(_ step: CurriculumStep) -> some View {
        switch step.kind {
        case .lesson(let markdown):
            lessonView(step, markdown: markdown)
        case .quiz:
            quizView(step)
        }
    }

    // MARK: Lesson

    private func lessonView(_ step: CurriculumStep, markdown: String) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                MarkdownContentView(text: markdown, isStreaming: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.border.opacity(0.5))

            HStack(spacing: 10) {
                if viewModel.curriculum.isComplete(step) {
                    Label("Read", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                }

                Spacer()

                Button {
                    viewModel.markLessonRead()
                    viewModel.advanceToNextStep()
                } label: {
                    HStack(spacing: 6) {
                        Text(viewModel.followingStep == nil ? "Finish" : "Mark read & continue")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: viewModel.followingStep == nil ? "checkmark" : "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: Quiz

    @ViewBuilder
    private func quizView(_ step: CurriculumStep) -> some View {
        if viewModel.isQuizComplete {
            quizResultView(step)
        } else if let question = viewModel.currentQuestion {
            quizQuestionView(question)
        } else {
            // Only reachable if a quiz step somehow carries no questions; the
            // parser rejects those, so this is a guard, not a real state.
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.warning)
                Text("This quiz has no questions.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
    }

    private func quizQuestionView(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Question \(viewModel.quizProgress.current) of \(viewModel.quizProgress.total)")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)

                    Text(question.q)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 8) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            answerButton(question: question, index: index, option: option)
                        }
                    }

                    if viewModel.showResult {
                        explanationCard(question)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.showResult {
                Divider().overlay(Theme.border.opacity(0.5))
                HStack {
                    Spacer()
                    Button {
                        viewModel.nextQuestion()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Next")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func answerButton(question: QuizQuestion, index: Int, option: String) -> some View {
        let letter = ["A", "B", "C", "D"].indices.contains(index) ? ["A", "B", "C", "D"][index] : "\(index)"
        let isSelected = viewModel.selectedAnswer == letter
        let isCorrect = question.correct == letter
        let revealed = viewModel.showResult

        return Button {
            viewModel.selectAnswer(letter)
        } label: {
            HStack(spacing: 10) {
                Text(letter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(letterColor(isCorrect: isCorrect, isSelected: isSelected, revealed: revealed))
                    .frame(width: 20, height: 20)
                    .background(
                        letterBackground(isCorrect: isCorrect, isSelected: isSelected, revealed: revealed),
                        in: RoundedRectangle(cornerRadius: 5)
                    )

                Text(option)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if revealed, isCorrect {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.success)
                } else if revealed, isSelected {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                rowBackground(isCorrect: isCorrect, isSelected: isSelected, revealed: revealed),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        rowBorder(isCorrect: isCorrect, isSelected: isSelected, revealed: revealed),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(revealed)
    }

    private func explanationCard(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.lastAnswerCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(viewModel.lastAnswerCorrect ? Theme.success : .red)
                Text(viewModel.lastAnswerCorrect ? "Correct" : "Not quite")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.lastAnswerCorrect ? Theme.success : .red)
            }
            if !question.explanation.isEmpty {
                Text(question.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func quizResultView(_ step: CurriculumStep) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                ZStack {
                    LearningProgressRing(
                        fraction: Double(viewModel.quizScorePercent) / 100,
                        color: viewModel.quizPassed ? Theme.success : Theme.warning,
                        lineWidth: 6,
                        size: 84
                    )
                    VStack(spacing: 0) {
                        Text("\(viewModel.quizScorePercent)%")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.primary)
                        Text("\(viewModel.quizScore)/\(viewModel.quizTotal)")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.top, 16)

                Text(viewModel.quizPassed ? "Passed" : "Below \(Curriculum.passThreshold)% — try again")
                    .font(.headline)
                    .foregroundStyle(viewModel.quizPassed ? Theme.success : Theme.warning)

                if !viewModel.wrongAnswers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(viewModel.wrongAnswers, id: \.question.id) { item in
                            wrongAnswerCard(item)
                        }
                    }
                }

                VStack(spacing: 8) {
                    if viewModel.quizPassed {
                        Button {
                            viewModel.advanceToNextStep()
                        } label: {
                            HStack(spacing: 6) {
                                Text(viewModel.followingStep == nil ? "Finish course" : "Next step")
                                    .font(.system(size: 13, weight: .semibold))
                                Image(systemName: viewModel.followingStep == nil ? "checkmark" : "arrow.right")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(Theme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            viewModel.retryQuiz()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Retake quiz")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Theme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onReviewWithAgent, !viewModel.wrongAnswers.isEmpty {
                        let prompt = viewModel.reviewPrompt
                        Button {
                            onReviewWithAgent(prompt)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 12))
                                Text("Review with Agent")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        viewModel.closeStep()
                    } label: {
                        Text("Back to outline")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Quiz \(step.title) scored \(viewModel.quizScorePercent) percent")
    }

    private func wrongAnswerCard(_ item: (question: QuizQuestion, selected: String)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.question.q)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("You: \(item.selected)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(.red)
                Text("Correct: \(item.question.correct)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.success)
            }

            if !item.question.explanation.isEmpty {
                Text(item.question.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Answer colors

    private func letterColor(isCorrect: Bool, isSelected: Bool, revealed: Bool) -> Color {
        if revealed {
            if isCorrect { return Theme.success }
            if isSelected { return .red }
            return Theme.tertiary
        }
        return isSelected ? Theme.accent : Theme.secondary
    }

    private func letterBackground(isCorrect: Bool, isSelected: Bool, revealed: Bool) -> Color {
        if revealed {
            if isCorrect { return Theme.success.opacity(0.15) }
            if isSelected { return Color.red.opacity(0.15) }
            return Theme.surfaceHover
        }
        return isSelected ? Theme.accent.opacity(0.2) : Theme.surfaceHover
    }

    private func rowBackground(isCorrect: Bool, isSelected: Bool, revealed: Bool) -> Color {
        if !revealed {
            return isSelected ? Theme.accent.opacity(0.08) : Theme.surface
        }
        if isCorrect { return Theme.success.opacity(0.08) }
        if isSelected { return Color.red.opacity(0.06) }
        return Theme.surface.opacity(0.5)
    }

    private func rowBorder(isCorrect: Bool, isSelected: Bool, revealed: Bool) -> Color {
        if !revealed {
            return isSelected ? Theme.accent : Theme.border
        }
        if isCorrect { return Theme.success }
        if isSelected { return .red }
        return Theme.border.opacity(0.4)
    }
}
