import Testing
import Foundation
@testable import HermesNative

@Suite("Maintainer refs")
struct MaintainerRefTests {

    // MARK: - Parsing single refs

    @Test("Parses a cron ref")
    func parsesCron() {
        #expect(MaintainerRef("cron:job_abc") == .cron(jobID: "job_abc"))
    }

    @Test("A bare id with no colon is treated as a cron job")
    func bareIDIsCron() {
        #expect(MaintainerRef("job_abc") == .cron(jobID: "job_abc"))
    }

    @Test("An unknown type round-trips as .other")
    func unknownType() {
        #expect(MaintainerRef("workflow:wf_1") == .other(type: "workflow", value: "wf_1"))
        #expect(MaintainerRef("workflow:wf_1")?.raw == "workflow:wf_1")
    }

    @Test("Empty or value-less refs fail to parse")
    func rejectsEmpty() {
        #expect(MaintainerRef("") == nil)
        #expect(MaintainerRef("   ") == nil)
        #expect(MaintainerRef("cron:") == nil)
    }

    @Test("Type is lowercased and whitespace trimmed")
    func normalizes() {
        #expect(MaintainerRef("  CRON : job_x ") == .cron(jobID: "job_x"))
    }

    // MARK: - List extraction

    @Test("Extracts the maintainers array from content")
    func parseList() {
        let content = #"{"id":"a","maintainers":["cron:j1","cron:j2"],"rows":[]}"#
        #expect(MaintainerRef.parseList(from: content) == [.cron(jobID: "j1"), .cron(jobID: "j2")])
    }

    @Test("Missing key or non-JSON content yields no maintainers")
    func parseListEmpty() {
        #expect(MaintainerRef.parseList(from: #"{"id":"a"}"#).isEmpty)
        #expect(MaintainerRef.parseList(from: "# a markdown doc").isEmpty)
    }

    // MARK: - Writing

    @Test("Writes maintainers as a top-level array, preserving other keys")
    func writeAddsKey() throws {
        let content = #"{"id":"a","rows":[]}"#
        let out = try #require(MaintainerRef.write([.cron(jobID: "j1")], into: content))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["maintainers"] as? [String] == ["cron:j1"])
        #expect(obj["id"] as? String == "a")
        #expect(obj["rows"] != nil)
    }

    @Test("Writing an empty list removes the key")
    func writeEmptyRemovesKey() throws {
        let content = #"{"id":"a","maintainers":["cron:j1"]}"#
        let out = try #require(MaintainerRef.write([], into: content))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["maintainers"] == nil)
    }

    @Test("Writing de-dups while preserving order")
    func writeDedups() throws {
        let content = #"{"id":"a"}"#
        let out = try #require(MaintainerRef.write(
            [.cron(jobID: "j1"), .cron(jobID: "j2"), .cron(jobID: "j1")], into: content))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["maintainers"] as? [String] == ["cron:j1", "cron:j2"])
    }

    @Test("Writing into non-JSON content fails (markdown can't declare maintainers)")
    func writeRejectsNonJSON() {
        #expect(MaintainerRef.write([.cron(jobID: "j1")], into: "# doc") == nil)
    }

    @Test("Parse→write round-trips")
    func roundTrip() throws {
        let content = #"{"id":"a","maintainers":["cron:j1","workflow:wf2"]}"#
        let refs = MaintainerRef.parseList(from: content)
        let out = try #require(MaintainerRef.write(refs, into: content))
        #expect(MaintainerRef.parseList(from: out) == refs)
    }
}
