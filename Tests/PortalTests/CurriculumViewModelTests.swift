import Foundation
import Testing
@testable import Portal

/// The player view model's chat hand-off: "Discuss this page" carries the
/// course, module and lesson text so the conversation is about what's open.
@Suite("Curriculum player: discuss this page")
@MainActor
internal struct CurriculumViewModelTests {

    private func makeStore() -> LearningStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("curriculum-vm-tests-\(UUID().uuidString)", isDirectory: true)
        return LearningStore(curriculumDirectory: dir)
    }

    private func course() -> Curriculum {
        Curriculum(
            title: "Linear Algebra",
            summary: "Vectors through eigenvalues.",
            modules: [
                CurriculumModule(
                    title: "Vectors",
                    overview: "The basics.",
                    steps: [
                        CurriculumStep(title: "What is a vector", kind: .lesson(markdown: "A vector has direction and magnitude.")),
                        CurriculumStep(title: "Vectors check", kind: .quiz(questions: [
                            QuizQuestion(q: "2+2?", options: ["A) 4", "B) 5"], correct: "A", explanation: "Arithmetic.")
                        ]))
                    ]
                )
            ]
        )
    }

    @Test("an opened lesson yields a prompt naming the course, module and lesson body")
    internal func lessonPrompt() throws {
        let vm = CurriculumViewModel(curriculum: course(), store: makeStore())
        let lesson = vm.curriculum.orderedSteps.first { !$0.isQuiz }
        vm.open(try #require(lesson))

        let prompt = vm.discussPrompt
        #expect(prompt.contains("course \"Linear Algebra\""))
        #expect(prompt.contains("lesson \"What is a vector\""))
        #expect(prompt.contains("module \"Vectors\""))
        #expect(prompt.contains("A vector has direction and magnitude."))
    }

    @Test("nothing open, or a quiz open, gives no discuss prompt")
    internal func noPromptWithoutLesson() throws {
        let vm = CurriculumViewModel(curriculum: course(), store: makeStore())
        #expect(vm.discussPrompt.isEmpty)

        let quiz = vm.curriculum.orderedSteps.first { $0.isQuiz }
        vm.open(try #require(quiz))
        #expect(vm.discussPrompt.isEmpty, "a quiz uses reviewPrompt, not discussPrompt")
    }
}
