import SwiftUI
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CurriculumViewModel")

/// Drives one course: which step is open, quiz state for quiz steps, and
/// progress writes back to `CurriculumStore`.
///
/// Quiz playback reuses `QuizState` rather than `QuizViewModel`. `QuizViewModel`
/// owns a save-and-clear lifecycle (`close()` persists a `PersistedQuizSession`
/// and tears down state), which would both fight step-to-step navigation and
/// litter the Learning list with a standalone quiz record per module quiz. Here
/// the score belongs to the step.
@MainActor
@Observable
internal final class CurriculumViewModel {

    /// The course being studied. Progress mutations land here first, then persist.
    internal private(set) var curriculum: Curriculum

    /// Open step, or nil while showing the course outline.
    internal private(set) var activeStep: CurriculumStep?

    // MARK: Quiz playback (only meaningful while a quiz step is active)

    internal private(set) var quizState: QuizState?
    internal private(set) var selectedAnswer: String?
    internal private(set) var showResult = false
    internal private(set) var lastAnswerCorrect = false

    /// Where progress is written. Injected so the dashboard and the player share
    /// one store, and so tests can hand over an isolated instance. Progress
    /// routes through the store's record methods (optimistic local fold +
    /// gateway event) rather than whole-course saves, so the server's
    /// commutative fold sees individual events, not blobs.
    private let store: LearningStore

    internal init(curriculum: Curriculum, store: LearningStore) {
        self.curriculum = curriculum
        self.store = store
    }

    // MARK: - Navigation

    /// Open a step. Quiz steps start a fresh attempt every time, so a retake is
    /// scored on its own merits rather than resuming a stale run.
    internal func open(_ step: CurriculumStep) {
        activeStep = step
        switch step.kind {
        case .lesson:
            quizState = nil
        case .quiz(let questions):
            quizState = QuizState(questions: questions, topic: step.title)
        }
        selectedAnswer = nil
        showResult = false
        lastAnswerCorrect = false
    }

    /// Return to the outline, leaving progress as recorded.
    internal func closeStep() {
        activeStep = nil
        quizState = nil
        selectedAnswer = nil
        showResult = false
    }

    /// Open the first incomplete step — the "Continue" affordance.
    internal func continueCourse() {
        guard let step = curriculum.nextStep else { return }
        open(step)
    }

    /// The step after the active one in course order, if any.
    internal var followingStep: CurriculumStep? {
        guard let activeStep else { return nil }
        let steps = curriculum.orderedSteps
        guard let index = steps.firstIndex(where: { $0.id == activeStep.id }),
              index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    /// Advance to the next step in order, or fall back to the outline when the
    /// active step was the last one.
    internal func advanceToNextStep() {
        if let next = followingStep {
            open(next)
        } else {
            closeStep()
        }
    }

    /// 1-based position of the active step, for "Step 3 of 12".
    internal var activeStepPosition: Int? {
        guard let activeStep else { return nil }
        guard let index = curriculum.orderedSteps.firstIndex(where: { $0.id == activeStep.id }) else {
            return nil
        }
        return index + 1
    }

    // MARK: - Lesson completion

    /// Mark the open lesson read and persist. Safe to call twice — the model
    /// keeps the first completion timestamp.
    internal func markLessonRead() {
        guard let activeStep, !activeStep.isQuiz else { return }
        curriculum.markLessonRead(stepID: activeStep.id)
        store.recordLessonRead(courseID: curriculum.id, stepID: activeStep.id)
    }

    // MARK: - Quiz playback

    internal var currentQuestion: QuizQuestion? { quizState?.currentQuestion }
    internal var isQuizComplete: Bool { quizState?.isComplete ?? false }
    internal var quizScore: Int { quizState?.score ?? 0 }
    internal var quizTotal: Int { quizState?.questions.count ?? 0 }
    internal var quizProgress: (current: Int, total: Int) { quizState?.progress ?? (0, 0) }

    /// Score of the in-flight attempt as a percentage.
    internal var quizScorePercent: Int {
        guard quizTotal > 0 else { return 0 }
        return Int(round(Double(quizScore) / Double(quizTotal) * 100))
    }

    /// Whether the finished attempt cleared the pass bar.
    internal var quizPassed: Bool {
        quizScorePercent >= Curriculum.passThreshold
    }

    /// Answer the current question. Ignored once answered, so a double-tap can't
    /// double-count the score.
    internal func selectAnswer(_ option: String) {
        guard selectedAnswer == nil, let question = currentQuestion else { return }
        selectedAnswer = option
        lastAnswerCorrect = quizState?.answer(questionID: question.id, option: option) ?? false
        showResult = true
    }

    /// Advance past the revealed question, recording the attempt when the last
    /// question closes out the quiz.
    internal func nextQuestion() {
        quizState?.advance()
        selectedAnswer = nil
        showResult = false

        guard quizState?.isComplete == true, let activeStep else { return }
        let percent = quizScorePercent
        curriculum.recordQuizAttempt(stepID: activeStep.id, scorePercent: percent)
        store.recordQuizAttempt(courseID: curriculum.id, stepID: activeStep.id, scorePercent: percent)
        log.info("Curriculum quiz step scored \(percent)% (pass \(Curriculum.passThreshold)%)")
    }

    /// Restart the active quiz step without leaving it.
    internal func retryQuiz() {
        guard let activeStep, case .quiz(let questions) = activeStep.kind else { return }
        quizState = QuizState(questions: questions, topic: activeStep.title)
        selectedAnswer = nil
        showResult = false
        lastAnswerCorrect = false
    }

    /// Wrong answers from the finished attempt, for the review list.
    internal var wrongAnswers: [(question: QuizQuestion, selected: String)] {
        quizState?.wrongAnswers ?? []
    }

    /// Prompt handed to chat for "Review with Agent" on a failed or partial quiz.
    /// Names the course and module so the agent has the context a standalone
    /// quiz review lacks.
    internal var reviewPrompt: String {
        guard let activeStep, let quizState else { return "" }
        let moduleTitle = curriculum.module(containing: activeStep)?.title ?? curriculum.title
        let wrongList = quizState.wrongAnswers.enumerated().map { index, item in
            let selectedText = ["A", "B", "C", "D"].firstIndex(of: item.selected)
                .flatMap { $0 < item.question.options.count ? item.question.options[$0] : item.selected }
                ?? item.selected
            return "Q\(index + 1): \(item.question.q)\n"
                + "  My answer: \(item.selected)) \(selectedText)\n"
                + "  Correct: \(item.question.correct)) \(item.question.correctAnswer)\n"
                + "  Explanation: \(item.question.explanation)"
        }.joined(separator: "\n\n")

        return "I'm working through the course \"\(curriculum.title)\" and just took the quiz "
            + "\"\(activeStep.title)\" in the module \"\(moduleTitle)\". "
            + "I scored \(quizScore)/\(quizTotal). Please help me understand what I got wrong:\n\n\(wrongList)"
    }

    // MARK: - Course-level actions

    /// Clear all progress and return to the outline. Local-only by design:
    /// the gateway's fold rules are monotonic (first stamp wins), so restart
    /// is a client presentation choice, not upstream history rewriting.
    internal func restartCourse() {
        curriculum.resetProgress()
        closeStep()
        store.resetCourseProgress(id: curriculum.id)
    }
}
