import Testing
import Foundation
@testable import HermesNative

@Suite("Clarify Request")
struct ClarifyRequestTests {

    @Test("clarify.request parses question, choices, and request_id")
    func parsesFullPayload() {
        let payload = AnyCodable.dictionary([
            "question": .string("Which database should I target?"),
            "choices": .array([.string("staging"), .string("production")]),
            "request_id": .string("ab12cd34"),
        ])
        let event = GatewayEvent.from(type: "clarify.request", payload: payload)
        guard case .clarifyRequest(let clarify) = event else {
            Issue.record("expected clarifyRequest, got \(event.debugName)")
            return
        }
        #expect(clarify.question == "Which database should I target?")
        #expect(clarify.choices == ["staging", "production"])
        #expect(clarify.requestID == "ab12cd34")
    }

    @Test("clarify.request without choices parses as free-text prompt")
    func parsesFreeTextPayload() {
        let payload = AnyCodable.dictionary([
            "question": .string("What time zone are you in?"),
            "request_id": .string("ff00aa11"),
        ])
        let event = GatewayEvent.from(type: "clarify.request", payload: payload)
        guard case .clarifyRequest(let clarify) = event else {
            Issue.record("expected clarifyRequest, got \(event.debugName)")
            return
        }
        #expect(clarify.choices.isEmpty)
        #expect(clarify.requestID == "ff00aa11")
    }
}
