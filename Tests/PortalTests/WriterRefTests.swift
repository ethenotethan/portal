import Testing
@testable import Portal

@Suite("Writer attribution")
internal struct WriterRefTests {

    @Test("cron stamp parses to the job id")
    internal func cronStampParses() {
        #expect(WriterRef.parse("cron:job_abc123") == .cron(jobID: "job_abc123"))
    }

    @Test("session stamp parses to the session id")
    internal func sessionStampParses() {
        #expect(WriterRef.parse("session:s-42") == .session(id: "s-42"))
    }

    @Test("legacy agent stamp with a cron session id resolves to the cron")
    internal func legacyCronSessionResolves() {
        let legacy = "agent:cron_ab12cd34ef56_20260729_081500"
        #expect(WriterRef.parse(legacy) == .cron(jobID: "ab12cd34ef56"))
    }

    @Test("legacy agent stamp with a normal session id stays a session")
    internal func legacyAgentSessionStaysSession() {
        #expect(WriterRef.parse("agent:s1") == .session(id: "s1"))
    }

    @Test("user and app device stamps both read as the user")
    internal func deviceStampsAreUser() {
        #expect(WriterRef.parse("user:device-1") == .user)
        #expect(WriterRef.parse("app:1a2b3c4d") == .user)
    }

    @Test("empty stamp parses to nil so rows can omit the line")
    internal func emptyIsNil() {
        #expect(WriterRef.parse("") == nil)
        #expect(WriterRef.parse("   ") == nil)
    }

    @Test("unknown shapes survive as raw text, never dropped")
    internal func unknownShapesSurvive() {
        #expect(WriterRef.parse("someone") == .other(raw: "someone"))
        #expect(WriterRef.parse("weird:thing") == .other(raw: "weird:thing"))
    }

    @Test("cron label resolves through the name lookup")
    internal func cronLabelResolvesName() {
        let writer = WriterRef.cron(jobID: "j1")
        #expect(writer.label(cronName: { $0 == "j1" ? "Nightly refresh" : nil }) == "Nightly refresh")
        #expect(writer.label(cronName: { _ in nil }) == "cron j1")
    }

    @Test("session label truncates the id to a readable prefix")
    internal func sessionLabelTruncates() {
        let writer = WriterRef.session(id: "abcdefghijklmnop")
        #expect(writer.label(cronName: { _ in nil }) == "agent session abcdefgh")
    }

    @Test("gateway stamps preserve their detail and use the gateway presentation")
    internal func gatewayStampPresentation() {
        let writer = WriterRef.parse("gateway:hermes")
        #expect(writer == .gateway(detail: "hermes"))
        #expect(writer?.icon == "server.rack")
        #expect(writer?.label(cronName: { _ in nil }) == "gateway (hermes)")

        let generic = WriterRef.parse("gateway:")
        #expect(generic?.label(cronName: { _ in nil }) == "gateway")
    }

    @Test("every writer kind has a distinct presentation fallback")
    internal func writerKindPresentationFallbacks() {
        let cases: [(writer: WriterRef, icon: String, label: String)] = [
            (.cron(jobID: "job-1"), "clock.arrow.circlepath", "cron job-1"),
            (.session(id: "s1"), "sparkles", "agent session s1"),
            (.user, "person.fill", "you"),
            (.gateway(detail: ""), "server.rack", "gateway"),
            (.other(raw: "future-writer"), "questionmark.circle", "future-writer"),
        ]

        for item in cases {
            #expect(item.writer.icon == item.icon)
            #expect(item.writer.label(cronName: { _ in nil }) == item.label)
        }
    }
}
