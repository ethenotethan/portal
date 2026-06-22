import SwiftUI

/// Modal sheet overlay presenting the interactive quiz UI.
/// Displays questions one at a time with multiple-choice answers,
/// progress tracking, and a final score review screen.
struct QuizSheet: View {
    @Bindable var viewModel: QuizViewModel
    let onClose: () -> Void
    let onReviewWithAgent: (String) -> Void
    let onOpenLearning: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                quizHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                // Mode picker
                modePicker
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Divider()
                    .background(Theme.border)
                    .padding(.top, 12)
                    .padding(.horizontal, 20)

                // Content — switch based on mode
                if viewModel.quizMode == .flashcards {
                    flashcardContent
                } else {
                    quizContent
                }

                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Theme.background)
        #if os(macOS)
        .frame(
            width: min((NSScreen.main?.visibleFrame.width ?? 800) * 0.65, 640),
            height: min((NSScreen.main?.visibleFrame.height ?? 700) * 0.7, 560)
        )
        #endif
    }

    // MARK: - Header

    private var quizHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiz")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .textCase(.uppercase)
                    Text(viewModel.state?.topic ?? "Quiz")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                }

                Spacer()

                // Score badge
                if let state = viewModel.state {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.success)
                        Text("Score: \(state.score)/\(state.questions.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                }

                // Learning button
                Button {
                    onOpenLearning()
                } label: {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open flashcard library")
                .help("Flashcard Library (⌘L)")

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
                .accessibilityLabel("Close quiz")
            }

            // Progress bar
            if !viewModel.isComplete {
                progressBar
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Question \(viewModel.progress.current)/\(viewModel.progress.total)")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.surfaceHover)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                        .frame(
                            width: max(0, min(geo.size.width, geo.size.width * CGFloat(viewModel.progress.current) / CGFloat(max(1, viewModel.progress.total)))),
                            height: 6
                        )
                        .animation(.easeInOut(duration: 0.3), value: viewModel.progress.current)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Question Screen

    private func questionScreen(_ question: QuizQuestion) -> some View {
        VStack(spacing: 0) {
            // Scrollable content area
            ScrollView {
                VStack(spacing: 0) {
                    // Question card
                    questionCard(question)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    // Answer buttons
                    answerButtons(question)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    // Result reveal
                    if viewModel.showResult {
                        resultReveal(question)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 16)
                    }
                }
            }

            // Persistent bottom bar
            bottomBar
        }
    }

    private func questionCard(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.q)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Answer Buttons

    private func answerButtons(_ question: QuizQuestion) -> some View {
        VStack(spacing: 10) {
            let labels = ["A", "B", "C", "D"]
            ForEach(Array(zip(labels, question.options)), id: \.0) { label, option in
                answerButtonRow(
                    label: label,
                    text: option,
                    isCorrect: label == question.correct,
                    isSelected: viewModel.selectedAnswer == label,
                    showResult: viewModel.showResult
                )
            }
        }
    }

    private func answerButtonRow(label: String, text: String, isCorrect: Bool, isSelected: Bool, showResult: Bool) -> some View {
        Button {
            viewModel.selectAnswer(label)
        } label: {
            HStack(spacing: 12) {
                // Letter badge
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(labelBadgeColor(isCorrect: isCorrect, isSelected: isSelected, showResult: showResult))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(labelBadgeBgColor(isCorrect: isCorrect, isSelected: isSelected, showResult: showResult))
                    )

                // Option text
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer()

                // Result icon
                if showResult {
                    if isCorrect {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.success)
                    } else if isSelected && !isCorrect {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(answerBgColor(isCorrect: isCorrect, isSelected: isSelected, showResult: showResult), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(answerBorderColor(isCorrect: isCorrect, isSelected: isSelected, showResult: showResult), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.showResult)
    }

    // MARK: - Result Reveal

    private func resultReveal(_ question: QuizQuestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: viewModel.lastAnswerCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(viewModel.lastAnswerCorrect ? Theme.success : .red)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.lastAnswerCorrect ? "Correct!" : "Incorrect")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(viewModel.lastAnswerCorrect ? Theme.success : .red)

                Text(question.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .background(viewModel.lastAnswerCorrect
            ? Theme.success.opacity(0.08)
            : Color.red.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Exit button — always visible during quiz
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                    Text("Exit Quiz")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Next / See Results button
            if viewModel.showResult {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.nextQuestion()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(viewModel.isComplete ? "See Results" : "Next Question")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                // Placeholder hint while user hasn't answered yet
                Text("Select an answer above")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.background.opacity(0.95))
        .overlay(alignment: .top) {
            Divider()
                .background(Theme.border.opacity(0.4))
        }
    }

    // MARK: - Final Screen

    private var finalScreen: some View {
        VStack(spacing: 20) {
            Spacer()

            // Score ring
            ZStack {
                Circle()
                    .stroke(Theme.surfaceHover, lineWidth: 8)
                    .frame(width: 100, height: 100)

                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.score) / CGFloat(max(1, viewModel.totalQuestions)))
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: viewModel.score)

                VStack(spacing: 2) {
                    Text("\(viewModel.score)/\(viewModel.totalQuestions)")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primary)
                    Text("Score")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
            }

            // Message
            VStack(spacing: 6) {
                Text(completionMessage)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.center)

                Text("You answered \(viewModel.score) out of \(viewModel.totalQuestions) questions correctly.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }

            // Wrong answers list
            if let state = viewModel.state, !state.wrongAnswers.isEmpty {
                wrongAnswersList(state)
                    .padding(.horizontal, 20)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 10) {
                Button {
                    onReviewWithAgent(viewModel.reviewPrompt)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 14))
                        Text("Review with Agent")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    onOpenLearning()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 14))
                        Text("Flashcard Library")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    onClose()
                } label: {
                    Text("Close")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var scoreColor: Color {
        let ratio = Double(viewModel.score) / Double(max(1, viewModel.totalQuestions))
        if ratio >= 0.8 { return Theme.success }
        if ratio >= 0.5 { return Theme.warning }
        return .red
    }

    private var completionMessage: String {
        let ratio = Double(viewModel.score) / Double(max(1, viewModel.totalQuestions))
        if ratio == 1.0 { return "🎉 Perfect Score!" }
        if ratio >= 0.8 { return "🌟 Great job!" }
        if ratio >= 0.5 { return "👍 Good effort!" }
        return "📚 Keep learning!"
    }

    private func wrongAnswersList(_ state: QuizState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Incorrect Answers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .textCase(.uppercase)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(state.wrongAnswers), id: \.question.id) { item in
                        wrongAnswerCard(item)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func wrongAnswerCard(_ item: (question: QuizQuestion, selected: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.question.q)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primary)

            HStack(spacing: 8) {
                Text("Your answer: \(item.selected)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

                Text("Correct: \(item.question.correct)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }

            Text(item.question.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading Screen

    private var loadingScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
                .tint(Theme.accent)
            Text("Generating quiz…")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Spacer()
        }
    }

    // MARK: - Error Screen

    private var errorScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.warning)
            Text("Quiz Generation Failed")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                onClose()
            } label: {
                Text("Close")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Color Helpers

    private func labelBadgeColor(isCorrect: Bool, isSelected: Bool, showResult: Bool) -> Color {
        if showResult {
            if isCorrect { return Theme.success }
            if isSelected { return .red }
            return Theme.tertiary
        }
        if isSelected { return Theme.accent }
        return Theme.secondary
    }

    private func labelBadgeBgColor(isCorrect: Bool, isSelected: Bool, showResult: Bool) -> Color {
        if showResult {
            if isCorrect { return Theme.success.opacity(0.15) }
            if isSelected { return Color.red.opacity(0.15) }
            return Theme.surfaceHover
        }
        if isSelected { return Theme.accent.opacity(0.2) }
        return Theme.surfaceHover
    }

    private func answerBgColor(isCorrect: Bool, isSelected: Bool, showResult: Bool) -> Color {
        if !showResult {
            return isSelected ? Theme.accent.opacity(0.08) : Theme.surface
        }
        if isCorrect { return Theme.success.opacity(0.08) }
        if isSelected { return Color.red.opacity(0.06) }
        return Theme.surface.opacity(0.5)
    }

    private func answerBorderColor(isCorrect: Bool, isSelected: Bool, showResult: Bool) -> Color {
        if !showResult {
            return isSelected ? Theme.accent : Theme.border
        }
        if isCorrect { return Theme.success }
        if isSelected { return .red }
        return Theme.border.opacity(0.4)
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(QuizMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.switchMode(to: mode)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.caption)
                        Text(mode.rawValue)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(viewModel.quizMode == mode ? Theme.primary : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        viewModel.quizMode == mode
                            ? Theme.accent.opacity(0.15)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)

                if mode != QuizMode.allCases.last {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1, height: 16)
                }
            }
        }
        .padding(2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Quiz Content (Original)

    @ViewBuilder
    private var quizContent: some View {
        if viewModel.isComplete {
            finalScreen
        } else if let question = viewModel.currentQuestion {
            questionScreen(question)
        } else if viewModel.errorMessage != nil {
            errorScreen
        } else {
            loadingScreen
        }
    }

    // MARK: - Flashcard Content

    @ViewBuilder
    private var flashcardContent: some View {
        if let deck = viewModel.flashcardDeck {
            FlashcardDeckView(
                deck: deck,
                onClose: {
                    viewModel.close()
                    onClose()
                },
                onDeckUpdated: { updatedDeck in
                    viewModel.updateDeck(updatedDeck)
                }
            )
        } else if viewModel.errorMessage != nil {
            errorScreen
        } else {
            loadingScreen
        }
    }
}
