import Testing
import Foundation
@testable import Portal

@Suite("Maintainer refs")
internal struct MaintainerRefTests {

    // MARK: - Parsing single refs

    @Test("Parses a cron ref")
    internal func parsesCron() {
        #expect(MaintainerRef("cron:job_abc") == .cron(jobID: "job_abc"))
    }

    @Test("A bare id with no colon is treated as a cron job")
    internal func bareIDIsCron() {
        #expect(MaintainerRef("job_abc") == .cron(jobID: "job_abc"))
    }

    @Test("An unknown type round-trips as .other")
    internal func unknownType() {
        #expect(MaintainerRef("workflow:wf_1") == .other(type: "workflow", value: "wf_1"))
        #expect(MaintainerRef("workflow:wf_1")?.raw == "workflow:wf_1")
    }

    @Test("Empty or value-less refs fail to parse")
    internal func rejectsEmpty() {
        #expect(MaintainerRef("") == nil)
        #expect(MaintainerRef("   ") == nil)
        #expect(MaintainerRef("cron:") == nil)
    }

    @Test("Type is lowercased and whitespace trimmed")
    internal func normalizes() {
        #expect(MaintainerRef("  CRON : job_x ") == .cron(jobID: "job_x"))
    }

    // MARK: - List extraction

    @Test("Extracts the maintainers array from content")
    internal func parseList() {
        let content = #"{"id":"a","maintainers":["cron:j1","cron:j2"],"rows":[]}"#
        #expect(MaintainerRef.parseList(from: content) == [.cron(jobID: "j1"), .cron(jobID: "j2")])
    }

    @Test("Missing key or non-JSON content yields no maintainers")
    internal func parseListEmpty() {
        #expect(MaintainerRef.parseList(from: #"{"id":"a"}"#).isEmpty)
        #expect(MaintainerRef.parseList(from: "# a markdown doc").isEmpty)
    }

    // MARK: - Writing

    @Test("Writes maintainers as a top-level array, preserving other keys")
    internal func writeAddsKey() throws {
        let content = #"{"id":"a","rows":[]}"#
        let out = try #require(MaintainerRef.write([.cron(jobID: "j1")], into: content))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["maintainers"] as? [String] == ["cron:j1"])
        #expect(obj["id"] as? String == "a")
        #expect(obj["rows"] != nil)
    }

    @Test("Writing an empty list removes the key")
    internal func writeEmptyRemovesKey() throws {
        let content = #"{"id":"a","maintainers":["cron:j1"]}"#
        let out = try #require(MaintainerRef.write([], into: content))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["maintainers"] == nil)
    }

    @Test("Writing de-dups while preserving order")
    internal func writeDedups() throws {
        let content = #"{"id":"a"}"#
        let out = try #require(MaintainerRef.write(
            [.cron(jobID: "j1"), .cron(jobID: "j2"), .cron(jobID: "j1")], into: content))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["maintainers"] as? [String] == ["cron:j1", "cron:j2"])
    }

    @Test("Writing into non-JSON content fails (markdown can't declare maintainers)")
    internal func writeRejectsNonJSON() {
        #expect(MaintainerRef.write([.cron(jobID: "j1")], into: "# doc") == nil)
    }

    /// `JSONSerialization` parses `-1e999` into a non-finite Double, which
    /// `isValidJSONObject` then rejects — a value that parses but can't
    /// round-trip. `write` must return nil rather than crash (NSException)
    /// when the surrounding content holds such a value.
    @Test("Writing into content with non-finite values fails gracefully")
    internal func writeRejectsNonFiniteContent() {
        let content = "{\"id\":\"a\",\"v\":-1e999}"
        #expect(MaintainerRef.write([.cron(jobID: "j1")], into: content) == nil)
    }

    @Test("Parse→write round-trips")
    internal func roundTrip() throws {
        let content = #"{"id":"a","maintainers":["cron:j1","workflow:wf2"]}"#
        let refs = MaintainerRef.parseList(from: content)
        let out = try #require(MaintainerRef.write(refs, into: content))
        #expect(MaintainerRef.parseList(from: out) == refs)
    }

    // MARK: - Identifiable

    @Test("id mirrors the stored raw string for every case")
    internal func idEqualsRaw() {
        #expect(MaintainerRef.cron(jobID: "job_abc").id == "cron:job_abc")
        #expect(MaintainerRef.other(type: "workflow", value: "wf_1").id == "workflow:wf_1")
        // Round-trip through the parser: a parsed ref's id must equal its raw form.
        #expect(MaintainerRef("cron:job_xyz")?.id == MaintainerRef("cron:job_xyz")?.raw)
    }
}
