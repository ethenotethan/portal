import Testing
@testable import Portal

@Suite("Quiz view model")
@MainActor
internal struct QuizViewModelTests {
    private func question(
        id: String,
        prompt: String,
        correct: String,
        options: [String] = ["Alpha", "Beta", "Gamma", "Delta"]
    ) -> QuizQuestion {
        QuizQuestion(
            q: prompt,
            options: options,
            correct: correct,
            explanation: "Because \(correct) is correct.",
            id: id
        )
    }

    @Test("fresh state exposes empty presentation values")
    internal func freshState() {
        let subject = QuizViewModel()

        #expect(subject.currentQuestion == nil)
        #expect(!subject.isComplete)
        #expect(subject.progress == (current: 0, total: 0))
        #expect(subject.score == 0)
        #expect(subject.totalQuestions == 0)
        #expect(subject.reviewPrompt.isEmpty)
        #expect(!subject.hasFlashcardDeck)
    }

    @Test("answer selection records once and advances through the quiz")
    internal func answerLifecycle() {
        let first = question(id: "q-1", prompt: "First?", correct: "B")
        let second = question(id: "q-2", prompt: "Second?", correct: "A")
        let subject = QuizViewModel()

        subject.load(questions: [first, second], topic: "Greek letters")
        #expect(subject.currentQuestion == first)
        #expect(subject.progress == (current: 1, total: 2))

        subject.selectAnswer("B")
        #expect(subject.selectedAnswer == "B")
        #expect(subject.lastAnswerCorrect)
        #expect(subject.showResult)
        #expect(subject.score == 1)

        // A second tap during the result reveal must not overwrite or rescore.
        subject.selectAnswer("A")
        #expect(subject.selectedAnswer == "B")
        #expect(subject.score == 1)

        subject.nextQuestion()
        #expect(subject.currentQuestion == second)
        #expect(subject.selectedAnswer == nil)
        #expect(!subject.showResult)
        #expect(subject.progress == (current: 2, total: 2))

        subject.selectAnswer("D")
        #expect(!subject.lastAnswerCorrect)
        subject.nextQuestion()
        #expect(subject.isComplete)
        #expect(subject.currentQuestion == nil)
        #expect(subject.score == 1)
    }

    @Test("review prompt expands answer letters to their option text")
    internal func reviewPrompt() {
        let subject = QuizViewModel()
        let question = question(
            id: "q-review",
            prompt: "Pick beta",
            correct: "B",
            options: ["Alpha", "Beta", "Gamma", "Delta"]
        )

        subject.load(questions: [question], topic: "Greek letters")
        subject.selectAnswer("C")

        #expect(subject.reviewPrompt.contains("quiz on \"Greek letters\""))
        #expect(subject.reviewPrompt.contains("I got 0/1"))
        #expect(subject.reviewPrompt.contains("My answer: C) Gamma"))
        #expect(subject.reviewPrompt.contains("Correct: B) Beta"))
        #expect(subject.reviewPrompt.contains("Explanation: Because B is correct."))
    }

    @Test("study modes expose stable labels and symbols")
    internal func modePresentation() {
        #expect(QuizMode.allCases.map(\.rawValue) == ["Quiz", "Flashcards"])
        #expect(QuizMode.quiz.icon == "questionmark.circle")
        #expect(QuizMode.flashcards.icon == "rectangle.on.rectangle")
    }
}
