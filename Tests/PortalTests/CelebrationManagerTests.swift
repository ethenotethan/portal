import Testing
import Foundation
@testable import Portal

/// The manager's own behavior, as opposed to the pure decision layer in
/// `CelebrationPreferencesTests`.
///
/// Serialized and restoring state in a `defer`, because `CelebrationManager` is a
/// singleton: these tests mutate the same instance the rest of the suite can see,
/// and a leaked `activeCelebration` would surface as an unrelated test failing.
///
/// Deliberately does not construct a `SettingsViewModel` — its `gatewayURL` and
/// `apiKey` setters write to the real login Keychain, so instantiating one in a
/// test overwrites the user's actual saved harness. Preferences are pushed in
/// through `apply(_:)` instead, which is the same path Settings uses.
@Suite("Celebration manager", .serialized)
@MainActor
internal struct CelebrationManagerTests {

    @Test("preview presents a celebration in the current configuration")
    internal func previewPresents() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        // Sound off: the suite runs unattended and an audible test is a bad
        // neighbor. The visual path is what's under test.
        manager.apply(prefs(enabled: true, soundEnabled: false))
        manager.activeCelebration = nil
        manager.preview()

        #expect(manager.activeCelebration != nil)
        #expect(manager.activeCelebration?.badge == "🥇")
    }

    @Test("preview ignores the throttle, so the button always does something")
    internal func previewBypassesThrottle() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        // `.subtle` throttles to one celebration every 8s. Two clicks of Preview
        // inside that window must both fire — a preview button that silently
        // does nothing reads as broken, and the user is trying to compare
        // settings.
        manager.apply(prefs(enabled: true, soundEnabled: false, intensity: .subtle))
        manager.preview()
        #expect(manager.activeCelebration != nil)

        manager.activeCelebration = nil
        manager.preview()
        #expect(manager.activeCelebration != nil)
    }

    @Test("preview respects the master switch")
    internal func previewHonorsTheMainSwitch() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        manager.apply(prefs(enabled: false, soundEnabled: false))
        manager.activeCelebration = nil
        manager.preview()
        // Off means off, even from the Settings pane that owns the switch.
        #expect(manager.activeCelebration == nil)
    }

    @Test("turning celebrations off clears one already on screen")
    internal func disablingClearsTheStage() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        manager.apply(prefs(enabled: true, soundEnabled: false))
        manager.preview()
        #expect(manager.activeCelebration != nil)

        // Flipping the switch mid-performance means "not this one either";
        // letting it run out looks like the toggle did nothing.
        manager.apply(prefs(enabled: false, soundEnabled: false))
        #expect(manager.activeCelebration == nil)
    }

    @Test("auditioning a sound does not start a performance")
    internal func auditionIsSilentVisually() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        manager.apply(prefs(enabled: true, soundEnabled: false))
        manager.activeCelebration = nil
        // Picking down a list of ten sounds must not queue ten 3.4s animations.
        // `.pop` is the shortest of the set, to keep the suite quiet and quick;
        // `audition` ignores `soundEnabled` by design, so this does play.
        manager.audition(.pop)
        #expect(manager.activeCelebration == nil)
    }

    @Test("the unconditional triggers still pass through the master switch")
    internal func unconditionalTriggersAreGated() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        manager.apply(prefs(enabled: false, soundEnabled: false))
        manager.activeCelebration = nil
        // These four never consult `adjustedChance`, so `celebrate`'s own guard
        // is the only thing standing between "off" and a celebration.
        manager.onSkillInstalled(name: "graphify")
        #expect(manager.activeCelebration == nil)
        manager.onFirstMessage(sessionID: "s1")
        #expect(manager.activeCelebration == nil)
        manager.onCronSuccess(jobName: "nightly")
        #expect(manager.activeCelebration == nil)
        manager.onReaction(occasion: "❤️")
        #expect(manager.activeCelebration == nil)
    }

    @Test("back-to-back celebrations are throttled")
    internal func throttleSuppressesTheSecond() {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        manager.apply(prefs(enabled: true, soundEnabled: false, intensity: .subtle))

        // `preview()` is the baseline rather than a first `onSkillInstalled`:
        // it's the only entry point that resets the throttle, and the manager is
        // a singleton whose `lastCelebrationDate` survives from whatever ran
        // before — so a plain trigger here could be suppressed by an earlier
        // test rather than by anything this one did.
        manager.preview()
        #expect(manager.activeCelebration != nil)

        manager.activeCelebration = nil
        // Inside `.subtle`'s 8s window. Without the throttle, two overlays fight
        // over one stage and each cancels the other's performance mid-beat.
        manager.onSkillInstalled(name: "second")
        #expect(manager.activeCelebration == nil)
    }

    @Test("a celebration auto-clears after the performance duration")
    internal func autoClearsAfterPerformance() async {
        let manager = CelebrationManager.shared
        let original = manager.preferences
        defer { restore(manager, to: original) }

        manager.apply(prefs(enabled: true, soundEnabled: false))
        manager.activeCelebration = nil
        manager.preview()
        #expect(manager.activeCelebration != nil)

        // Wait long enough for the auto-clear DispatchWorkItem to fire.
        // The work item is created in `celebrate()` (line 199) and fires after
        // `performanceDuration`. We wait 1s past that to be safe on a loaded
        // machine, but not so long that the serialized suite is dominated by it.
        let wait = CelebrationManager.performanceDuration + 1
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

        // The closure body (self?.activeCelebration = nil) must have fired.
        #expect(manager.activeCelebration == nil)
    }

    // MARK: - Helpers

    private func prefs(
        enabled: Bool,
        soundEnabled: Bool,
        intensity: CelebrationIntensity = .normal
    ) -> CelebrationPreferences {
        CelebrationPreferences(
            isEnabled: enabled,
            style: .confetti,
            intensity: intensity,
            particlesEnabled: true,
            soundEnabled: soundEnabled,
            sound: .pop
        )
    }

    /// Put the singleton back as it was. `apply(false)` first because that is the
    /// only public path that clears a pending auto-clear timer — otherwise this
    /// test's 3.4s work item fires during a later one and blanks its stage.
    private func restore(_ manager: CelebrationManager, to original: CelebrationPreferences) {
        var off = original
        off.isEnabled = false
        manager.apply(off)
        manager.apply(original)
        manager.activeCelebration = nil
    }
}
