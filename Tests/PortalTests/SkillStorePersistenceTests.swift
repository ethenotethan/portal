import Testing
import Foundation
@testable import Portal

/// Coverage for the two properties `SkillStoreDisk.save` must keep:
///
/// 1. **It runs off the main actor.** Every skill entry carries its complete
///    SKILL.md content, and encoding the array took 287ms on the main thread —
///    a watchdog-reported beachball on every skill refresh (stack ending in
///    `JSONWriter.serializeString` under `SkillStore.persistToDisk`). `save`
///    is `nonisolated` and `persistToDisk` hops to a detached task; the
///    round-trip test below calls it from off-main, so removing `nonisolated`
///    is a compile-time failure here before it is a beachball in the app.
///
/// 2. **Under test it never touches real user data.** This enum was one of
///    the unguarded Application Support writers the ChatHistoryStore incident
///    exposed: `save` runs from production code a test merely constructs, and
///    the real `skill-store.json` (plus the cache-freshness keys in
///    UserDefaults.standard) are live app state.
@Suite("SkillStore persistence")
internal struct SkillStorePersistenceTests {

    private static func fixtureSkill(name: String) -> SkillInfo {
        SkillInfo(
            name: name,
            description: "isolation probe",
            category: "test",
            source: "test",
            identifier: nil,
            tags: ["probe"],
            skillMdPath: nil,
            skillDir: nil,
            skillMdPreview: nil,
            skillMdFullContent: String(repeating: "x", count: 1_000),
            slashCommand: "/probe"
        )
    }

    @Test("skill persistence is redirected away from Application Support")
    internal func storageAvoidsApplicationSupport() {
        let dir = SkillStoreDisk.storageDirForTesting.path
        #expect(
            !dir.contains("Application Support"),
            "a test run would overwrite the user's real skill-store.json: \(dir)"
        )
    }

    @Test("save is callable off the main actor and round-trips")
    internal func saveRoundTripsFromBackground() async throws {
        let skills = [Self.fixtureSkill(name: "isolation-probe-\(UUID().uuidString)")]
        // Off-main on purpose: this line stops compiling if `save` regains
        // main-actor isolation, which is the guard for the 287ms encode hang.
        await Task.detached(priority: .background) {
            SkillStoreDisk.save(skills)
        }.value

        let loaded = await MainActor.run { SkillStoreDisk.loadFromFileForTesting() }
        #expect(loaded?.first?.name == skills[0].name)
        #expect(loaded?.first?.skillMdFullContent == skills[0].skillMdFullContent)
    }

    @Test("persistToDisk hops off the main actor")
    @MainActor
    internal func persistIsDetached() throws {
        // Structural pin, same style as CanvasRelayoutGuardTests: the hop is a
        // property of the call site, not expressible as pure math.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Portal/Services/SkillStore.swift"),
            encoding: .utf8
        )
        let persistBody = source.components(separatedBy: "private func persistToDisk()").last ?? ""
        #expect(
            persistBody.prefix(700).contains("Task.detached"),
            """
            persistToDisk must hand the encode to a detached task — inline it \
            and every skill refresh blocks the main thread for the length of a \
            full-catalog JSON encode (measured at 287ms, a beachball).
            """
        )
    }
}
