import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "QuizViewModel")

/// ViewModel for the Quiz Mode feature. Manages quiz state, answer evaluation,
/// and progression through questions. All evaluation is local — no further
/// agent calls are made during the quiz.
///
/// Supports two modes: multiple-choice quiz and flashcard study with SM-2 SRS.
@MainActor
@Observable
final class QuizViewModel {
    // MARK: - Mode

    /// Which study mode is currently active.
    var quizMode: QuizMode = .quiz

    // MARK: - Quiz State (MC)

    var state: QuizState?
    var currentQuestion: QuizQuestion? { state?.currentQuestion }
    var isComplete: Bool { state?.isComplete ?? false }
    var progress: (current: Int, total: Int) { state?.progress ?? (0, 0) }
    var score: Int { state?.score ?? 0 }
    var totalQuestions: Int { state?.questions.count ?? 0 }

    /// The user's selected answer for the current question, if any.
    var selectedAnswer: String?
    /// Whether we're showing the result reveal for the current question.
    var showResult: Bool = false
    /// Whether the last answer was correct (for color feedback).
    var lastAnswerCorrect: Bool = false
    /// Error message if quiz/flashcard generation fails.
    var errorMessage: String?

    // MARK: - Flashcard State

    /// The active flashcard deck being studied.
    var flashcardDeck: FlashcardDeck?

    /// Topic to send to chat when user taps "Review with Agent".
    var reviewPrompt: String {
        guard let state else { return "" }
        let wrongList = state.wrongAnswers.enumerated().map { idx, item in
            let selectedText = ["A", "B", "C", "D"].firstIndex(of: item.selected)
                .flatMap { $0 < item.question.options.count ? item.question.options[$0] : item.selected } ?? item.selected
            let correctText = item.question.correctAnswer
            return "Q\(idx + 1): \(item.question.q)\n"
                + "  My answer: \(item.selected)) \(selectedText)\n"
                + "  Correct: \(item.question.correct)) \(correctText)\n"
                + "  Explanation: \(item.question.explanation)"
        }.joined(separator: "\n\n")
        return "I just completed a quiz on \"\(state.topic)\". I got \(state.score)/\(state.questions.count). Please review my wrong answers:\n\n\(wrongList)"
    }

    /// Load questions from parsed JSON and reset state.
    func load(questions: [QuizQuestion], topic: String) {
        state = QuizState(questions: questions, topic: topic)
        selectedAnswer = nil
        showResult = false
        errorMessage = nil
    }

    /// Select an answer option ("A", "B", "C", "D").
    func selectAnswer(_ option: String) {
        guard selectedAnswer == nil, let question = currentQuestion else { return }
        selectedAnswer = option
        let correct = state?.answer(questionID: question.id, option: option) ?? false
        lastAnswerCorrect = correct
        showResult = true
    }

    /// Advance to the next question (or mark complete).
    func nextQuestion() {
        state?.advance()
        selectedAnswer = nil
        showResult = false
        if state?.isComplete == true {
            log.info("Quiz completed: score \(self.score)/\(self.totalQuestions)")
        }
    }

    /// Close the quiz and clear all state.
    func close() {
        state = nil
        selectedAnswer = nil
        showResult = false
        lastAnswerCorrect = false
        errorMessage = nil
        flashcardDeck = nil
        quizMode = .quiz
    }

    // MARK: - Flashcard Methods

    /// Load a flashcard deck and switch to flashcard mode.
    func load(deck: FlashcardDeck) {
        flashcardDeck = deck
        quizMode = .flashcards
        errorMessage = nil
    }

    /// Update the deck after a study session (persisted SRS state).
    func updateDeck(_ deck: FlashcardDeck) {
        flashcardDeck = deck
        SRSStore.shared.saveDeck(deck)
    }

    /// Switch between quiz and flashcard modes.
    func switchMode(to mode: QuizMode) {
        quizMode = mode
    }
}

// MARK: - Quiz Mode

/// The type of study session to display.
enum QuizMode: String, CaseIterable {
    case quiz = "Quiz"
    case flashcards = "Flashcards"

    var icon: String {
        switch self {
        case .quiz: return "questionmark.circle"
        case .flashcards: return "rectangle.on.rectangle"
        }
    }
}
