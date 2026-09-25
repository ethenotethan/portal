import Testing
@testable import Portal

@Suite("Quiz response parsing")
internal struct QuizResponseTests {
    private let validQuestion = """
        {"q":"Capital of France?","options":["Paris","Rome","Lima","Oslo"],"correct":"A","explanation":"Paris is the capital."}
        """

    @Test("extracts a strict quiz object from a JSON markdown fence")
    internal func extractsJSONFence() throws {
        let response = """
            Here is your quiz:
            ```json
            {"questions":[\(validQuestion)]}
            ```
            """

        let questions = try #require(QuizResponse.extract(from: response))

        #expect(questions.count == 1)
        #expect(questions[0].q == "Capital of France?")
        #expect(questions[0].correctAnswer == "Paris")
    }

    @Test("lenient object parsing keeps valid questions when one item is malformed")
    internal func lenientObjectDropsMalformedQuestion() throws {
        let response = """
            {"questions":[
              \(validQuestion),
              {"q":"Incomplete","options":["one","two","three","four"],"correct":"A"}
            ]}
            """

        let questions = try #require(QuizResponse.extract(from: response))

        #expect(questions.count == 1)
        #expect(questions[0].q == "Capital of France?")
    }

    @Test("extracts a direct question array from an unlabelled markdown fence")
    internal func extractsFencedQuestionArray() throws {
        let response = """
            ```
            [\(validQuestion)]
            ```
            """

        let questions = try #require(QuizResponse.extract(from: response))

        #expect(questions.count == 1)
        #expect(questions[0].explanation == "Paris is the capital.")
    }
}
