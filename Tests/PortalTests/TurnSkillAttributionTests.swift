import Testing
import Foundation
@testable import Portal

/// Skills reached the agent but were never recorded: attachments lived only in a
/// published array (lost on session switch), turns kept no note of what shaped
/// them, and agent-initiated `skill_view` loads were invisible entirely. These
/// pin the recording rules.
@Suite("Turn Skill Records")
internal struct TurnSkillRecordTests {

    @Test("a skill attached twice in one turn is recorded once")
    internal func attachedDeduplicates() {
        var records: [TurnSkillRecord] = []
        records.appendSkillRecord(TurnSkillRecord(name: "graphify", origin: .attached))
        records.appendSkillRecord(TurnSkillRecord(name: "graphify", origin: .attached))
        #expect(records.count == 1)
    }

    /// Attached-then-read is two true facts about the turn: the user chose it,
    /// and the agent went back to it. Collapsing them would lose the second.
    @Test("the same skill attached and agent-loaded is two records")
    internal func originsAreDistinct() {
        var records: [TurnSkillRecord] = []
        records.appendSkillRecord(TurnSkillRecord(name: "graphify", origin: .attached))
        records.appendSkillRecord(TurnSkillRecord(name: "graphify", origin: .loaded))
        #expect(records.count == 2)
        #expect(Set(records.map(\.origin)) == [.attached, .loaded])
    }

    @Test("insertion order is preserved")
    internal func preservesOrder() {
        var records: [TurnSkillRecord] = []
        for name in ["b", "a", "c"] {
            records.appendSkillRecord(TurnSkillRecord(name: name, origin: .loaded))
        }
        #expect(records.map(\.name) == ["b", "a", "c"])
    }

    @Test("an empty category falls back rather than rendering blank")
    internal func emptyCategoryFallsBack() {
        #expect(TurnSkillRecord(name: "x", category: "", origin: .loaded).category == "general")
    }

    @Test("an attached record carries the catalog category")
    internal func attachedCarriesCategory() {
        let skill = SkillInfo(
            name: "graphify",
            description: "",
            category: "knowledge",
            source: "local",
            identifier: nil,
            tags: [],
            skillMdPath: nil,
            skillDir: nil,
            skillMdPreview: nil,
            skillMdFullContent: nil,
            slashCommand: "graphify"
        )
        let record = TurnSkillRecord.attached(skill)
        #expect(record.category == "knowledge")
        #expect(record.origin == .attached)
        #expect(record.name == "graphify")
    }
}

/// The gateway sends a *rendered label* for a tool call, not raw arguments, so
/// attributing an agent-initiated skill load means reading the skill name back
/// out of that label. These cover the shapes `agent/display.py` can produce.
@Suite("Skill Name From skill_view Label")
internal struct SkillViewLabelTests {

    @Test("a bare skill name is the skill")
    internal func bareName() {
        #expect(TurnSkillRecord.skillName(fromViewLabel: "graphify") == "graphify")
    }

    /// Reading a skill's linked reference/template/script reports
    /// "<skill> → <path>"; the attribution is the skill, not the file.
    @Test("a linked-file read attributes the skill, not the file")
    internal func linkedFileRead() {
        #expect(TurnSkillRecord.skillName(fromViewLabel: "graphify → references/api.md") == "graphify")
    }

    @Test("a plugin-qualified name survives intact")
    internal func qualifiedName() {
        #expect(
            TurnSkillRecord.skillName(fromViewLabel: "superpowers:writing-plans")
                == "superpowers:writing-plans"
        )
    }

    /// Friendly labels are a host-side setting; with them off the preview
    /// arrives as raw args. Attribution must not depend on that setting.
    @Test("the raw-args form is parsed when friendly labels are disabled")
    internal func rawArgsForm() {
        #expect(TurnSkillRecord.skillName(fromViewLabel: "name=graphify") == "graphify")
        #expect(
            TurnSkillRecord.skillName(fromViewLabel: "name=graphify, file_path=refs/a.md") == "graphify"
        )
        #expect(TurnSkillRecord.skillName(fromViewLabel: "name=\"graphify\"") == "graphify")
    }

    /// The gateway truncates previews to 80 chars; a clipped label must not
    /// record the ellipsis as part of the skill name.
    @Test("a truncated label drops the ellipsis")
    internal func truncatedLabel() {
        #expect(TurnSkillRecord.skillName(fromViewLabel: "some-very-long-skill…") == "some-very-long-skill")
        #expect(TurnSkillRecord.skillName(fromViewLabel: "some-very-long-skill...") == "some-very-long-skill")
    }

    @Test("surrounding whitespace is trimmed")
    internal func trimsWhitespace() {
        #expect(TurnSkillRecord.skillName(fromViewLabel: "  graphify  ") == "graphify")
    }

    /// A label nothing name-shaped can be read from is skipped, rather than
    /// recorded as a skill named "" — an empty chip would be worse than no chip.
    @Test("an unreadable label yields no attribution")
    internal func unreadableLabelIsSkipped() {
        #expect(TurnSkillRecord.skillName(fromViewLabel: "") == nil)
        #expect(TurnSkillRecord.skillName(fromViewLabel: "   ") == nil)
        #expect(TurnSkillRecord.skillName(fromViewLabel: "→ references/api.md") == nil)
    }
}

/// A turn's skills have to survive being written to disk and read back, or the
/// attribution only lasts as long as the process.
@Suite("Turn Skill Persistence")
internal struct TurnSkillPersistenceTests {

    private func roundTrip(_ message: ChatMessage) throws -> ChatMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(ChatMessage.self, from: data)
    }

    @Test("skills round-trip through the transcript encoding")
    internal func skillsRoundTrip() throws {
        var message = ChatMessage(role: .assistant, content: "done")
        message.skills = [
            TurnSkillRecord(name: "graphify", category: "knowledge", origin: .attached),
            TurnSkillRecord(name: "writing-plans", origin: .loaded),
        ]

        let decoded = try roundTrip(message)
        #expect(decoded.skills.count == 2)
        #expect(decoded.skills[0].name == "graphify")
        #expect(decoded.skills[0].category == "knowledge")
        #expect(decoded.skills[0].origin == .attached)
        #expect(decoded.skills[1].origin == .loaded)
    }

    /// Turns persisted before this existed have no `skills` key. They must decode
    /// as "not recorded" rather than failing the whole transcript load.
    @Test("a turn persisted before skill capture still decodes")
    internal func legacyTurnDecodes() throws {
        let json = #"""
        {"id":"\#(UUID().uuidString)","role":"assistant","content":"hi","isStreaming":false,"toolCalls":[]}
        """#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(decoded.skills.isEmpty)
    }
}

/// The rail/dashboard replay past turns from the transcript, so the builder is
/// what makes "which skill did this turn use?" answerable after the fact.
@Suite("Session Turn Skill Replay")
@MainActor
internal struct SessionTurnSkillTests {

    private func message(
        _ role: ChatMessage.Role,
        _ content: String,
        skills: [TurnSkillRecord] = []
    ) -> ChatMessage {
        var message = ChatMessage(role: role, content: content)
        message.skills = skills
        return message
    }

    @Test("a past turn replays the skills recorded on it")
    internal func pastTurnCarriesSkills() {
        let turns = SessionTurnBuilder.turns(from: [
            message(.user, "map this"),
            message(.assistant, "mapped", skills: [
                TurnSkillRecord(name: "graphify", origin: .attached),
                TurnSkillRecord(name: "writing-plans", origin: .loaded),
            ]),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].skills.map(\.name) == ["graphify", "writing-plans"])
    }

    /// A turn interrupted before completion never got stamped, but the user
    /// message it answered did — so the attached set is still recoverable.
    @Test("an unstamped turn falls back to the prompt's attached skills")
    internal func fallsBackToPromptSkills() {
        let turns = SessionTurnBuilder.turns(from: [
            message(.user, "map this", skills: [TurnSkillRecord(name: "graphify", origin: .attached)]),
            message(.assistant, "interrupted"),
        ])
        #expect(turns[0].skills.map(\.name) == ["graphify"])
    }

    /// Distinguishes "no skills" from "not recorded": gateway-resumed history
    /// carries neither, and the panel says so rather than claiming none.
    @Test("a turn with no skill data anywhere records none")
    internal func noSkillDataIsEmpty() {
        let turns = SessionTurnBuilder.turns(from: [
            message(.user, "hello"),
            message(.assistant, "hi"),
        ])
        #expect(turns[0].skills.isEmpty)
    }

    @Test("each turn keeps its own skills as the attachment set changes")
    internal func perTurnIsolation() {
        let turns = SessionTurnBuilder.turns(from: [
            message(.user, "first"),
            message(.assistant, "a", skills: [TurnSkillRecord(name: "graphify", origin: .attached)]),
            message(.user, "second"),
            message(.assistant, "b", skills: [TurnSkillRecord(name: "plan", origin: .attached)]),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].skills.map(\.name) == ["graphify"])
        #expect(turns[1].skills.map(\.name) == ["plan"])
    }
}

/// Pin the live event paths as well as the value-level persistence rules above.
/// These are the two paths that stamp a completed turn: the session currently
/// on screen and a different session continuing in the background.
@Suite("Live Turn Skill Attribution")
@MainActor
internal struct LiveTurnSkillAttributionTests {

    private func skill(_ name: String = "graphify") -> SkillInfo {
        SkillInfo(
            name: name,
            description: "",
            category: "knowledge",
            source: "local",
            identifier: nil,
            tags: [],
            skillMdPath: nil,
            skillDir: nil,
            skillMdPreview: nil,
            skillMdFullContent: nil,
            slashCommand: name
        )
    }

    private func complete(_ text: String = "done") -> GatewayEvent {
        .messageComplete(payload: MessageCompletePayload(
            text: text,
            status: "complete",
            usage: nil,
            reasoning: nil,
            rendered: nil,
            warning: nil
        ))
    }

    private func loadedSkillEvent(id: String = "skill-tool") -> GatewayEvent {
        .toolStart(payload: ToolStartPayload(
            toolID: id,
            name: "skill_view",
            context: "graphify"
        ))
    }

    @Test("the visible turn records attached and agent-loaded skills")
    internal func visibleTurnRecordsBothOrigins() {
        let vm = ChatViewModel()
        let sessionID = "visible-skills-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sessionID)
        vm.attachSkill(skill())

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionID)
        vm.receiveGatewayEventForTesting(loadedSkillEvent(), sessionID: sessionID)

        #expect(vm.currentTurnSkills.map(\.id) == ["attached:graphify", "loaded:graphify"])

        vm.receiveGatewayEventForTesting(complete(), sessionID: sessionID)
        let assistant = vm.messages.last { $0.role == .assistant }
        #expect(assistant?.skills.map(\.id) == ["attached:graphify", "loaded:graphify"])
        #expect(vm.loadedSkills.isEmpty)
    }

    @Test("a background turn stamps its own skills, not the visible session's")
    internal func backgroundTurnRecordsItsOwnSkills() async {
        let vm = ChatViewModel()
        let backgroundID = "background-skills-\(UUID().uuidString)"
        let visibleID = "visible-other-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: backgroundID)
        vm.attachSkill(skill())
        _ = vm.beginSwitchToSession(key: visibleID)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: backgroundID)
        vm.receiveGatewayEventForTesting(
            loadedSkillEvent(id: "background-skill-tool"),
            sessionID: backgroundID
        )
        vm.receiveGatewayEventForTesting(complete("background done"), sessionID: backgroundID)

        // Background transcript writes intentionally use a detached task. Poll
        // the real store rather than asserting against an in-memory copy that
        // production deliberately releases after completion.
        var assistant: ChatMessage?
        for _ in 0..<100 where assistant == nil {
            assistant = ChatHistoryStore.shared.loadMessages(forSession: backgroundID)?
                .last { $0.role == .assistant }
            if assistant == nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(assistant?.skills.map(\.id) == ["attached:graphify", "loaded:graphify"])
        #expect(vm.currentSessionID == visibleID)
        #expect(vm.loadedSkills.isEmpty)
    }

    @Test("attached skills survive switching away and back")
    internal func attachmentsAreSessionState() {
        let vm = ChatViewModel()
        let sessionA = "skills-a-\(UUID().uuidString)"
        let sessionB = "skills-b-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sessionA)
        vm.attachSkill(skill())

        _ = vm.beginSwitchToSession(key: sessionB)
        #expect(vm.activeSkills.isEmpty)

        _ = vm.beginSwitchToSession(key: sessionA)
        #expect(vm.activeSkills.map(\.name) == ["graphify"])
    }
}
