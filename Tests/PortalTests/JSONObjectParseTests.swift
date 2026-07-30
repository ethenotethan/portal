import Foundation
import Testing
@testable import Portal

@Suite("JSON object parse")
internal struct JSONObjectParseTests {

    @Test("A top-level object parses into a dictionary")
    internal func parsesObject() {
        let obj = JSONObjectParse.object(from: #"{"a": 1, "b": "two"}"#)
        #expect(obj?["a"] as? Int == 1)
        #expect(obj?["b"] as? String == "two")
    }

    @Test("Nested structure is preserved")
    internal func parsesNested() {
        let obj = JSONObjectParse.object(from: #"{"outer": {"inner": [1, 2]}}"#)
        let outer = obj?["outer"] as? [String: Any]
        #expect((outer?["inner"] as? [Any])?.count == 2)
    }

    @Test("Malformed JSON yields nil rather than throwing")
    internal func malformedIsNil() {
        #expect(JSONObjectParse.object(from: "{not json") == nil)
        #expect(JSONObjectParse.object(from: "") == nil)
    }

    @Test("Valid JSON that isn't a top-level object is nil")
    internal func nonObjectTopLevelIsNil() {
        // A JSON array and a bare scalar are valid JSON but not [String: Any].
        #expect(JSONObjectParse.object(from: "[1, 2, 3]") == nil)
        #expect(JSONObjectParse.object(from: "42") == nil)
        #expect(JSONObjectParse.object(from: #""just a string""#) == nil)
    }

    @Test("An empty object parses to an empty dictionary, not nil")
    internal func emptyObject() {
        let obj = JSONObjectParse.object(from: "{}")
        #expect(obj != nil)
        #expect(obj?.isEmpty == true)
    }
}
