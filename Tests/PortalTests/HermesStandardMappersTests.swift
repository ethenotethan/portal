import Foundation
import Testing
@testable import Portal

@Suite("Hermes Standard mappers")
internal struct HermesStandardMappersTests {

    // The Standard source structs only decode (no memberwise init), so build
    // them from JSON — which also exercises their init(from:) fallbacks.
    private func decodeCron(_ json: String) throws -> HermesStandardCronJob {
        try JSONDecoder().decode(HermesStandardCronJob.self, from: Data(json.utf8))
    }

    private func decodeSkill(_ json: String) throws -> HermesStandardSkill {
        try JSONDecoder().decode(HermesStandardSkill.self, from: Data(json.utf8))
    }

    // MARK: - CronJob(standard:)

    @Test("A Standard cron job maps its present fields and nils the absent ones")
    internal func cronMapsFields() throws {
        let src = try decodeCron("""
        {"id": "job-1", "name": "Nightly", "schedule": "0 0 * * *",
         "enabled": true, "state": "scheduled", "deliver": "local",
         "last_run_status": "ok", "last_run_error": null}
        """)
        let job = CronJob(standard: src)
        #expect(job.id == "job-1")
        #expect(job.name == "Nightly")
        #expect(job.schedule == "0 0 * * *")
        #expect(job.enabled == true)
        #expect(job.state == "scheduled")
        #expect(job.deliver == "local")
        #expect(job.lastStatus == "ok")
        // No HTTP source for these — must be nil so the row degrades cleanly.
        #expect(job.nextRunAt == nil)
        #expect(job.lastRunAt == nil)
        #expect(job.promptPreview == nil)
        #expect(job.prompt == nil)
    }

    @Test("A disabled Standard job carries enabled=false and its error through")
    internal func cronMapsDisabledWithError() throws {
        let src = try decodeCron("""
        {"id": "job-2", "name": "Broken", "schedule": "* * * * *",
         "enabled": false, "state": "paused", "deliver": "email",
         "last_run_status": "error", "last_run_error": "boom"}
        """)
        let job = CronJob(standard: src)
        #expect(job.enabled == false)
        #expect(job.lastError == "boom")
        #expect(job.lastStatus == "error")
    }

    // MARK: - SkillInfo(standard:)

    @Test("A Standard skill maps provenance to source and synthesizes a slash command")
    internal func skillMapsFields() throws {
        let src = try decodeSkill("""
        {"name": "Deep Research", "description": "does research",
         "category": "analysis", "enabled": true, "provenance": "builtin"}
        """)
        let skill = SkillInfo(standard: src)
        #expect(skill.name == "Deep Research")
        #expect(skill.description == "does research")
        #expect(skill.category == "analysis")
        #expect(skill.source == "builtin")
        // Slash command is synthesized: lowercased, spaces → hyphens.
        #expect(skill.slashCommand == "/deep-research")
        // Fields with no upstream source stay empty/nil.
        #expect(skill.identifier == nil)
        #expect(skill.tags.isEmpty)
        #expect(skill.skillMdPath == nil)
    }

    @Test("Slash-command synthesis lowercases and hyphenates multi-word names")
    internal func slashCommandSynthesis() throws {
        let src = try decodeSkill("""
        {"name": "My Cool Skill", "description": "", "category": "general",
         "enabled": true, "provenance": "local"}
        """)
        #expect(SkillInfo(standard: src).slashCommand == "/my-cool-skill")
    }

    @Test("Absent optional skill fields fall back via the decoder before mapping")
    internal func skillDecoderFallbacks() throws {
        // Only name is required; description/category/provenance have defaults.
        let src = try decodeSkill(#"{"name": "Bare"}"#)
        let skill = SkillInfo(standard: src)
        #expect(skill.description.isEmpty)
        #expect(skill.category == "general")
        #expect(skill.source == "local")
        #expect(skill.slashCommand == "/bare")
    }
}
