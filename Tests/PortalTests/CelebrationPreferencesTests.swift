import Testing
import Foundation
@testable import Portal

/// The celebration effect used to be unconfigurable and, separately, only
/// half-presented: `ContentView` tested `activeCelebration != nil` and then
/// rendered 60 confetti particles regardless, so a `.milestone(level:message:)`
/// payload — "Skill unlocked: X" — was computed and discarded, and there was no
/// switch to turn any of it off.
///
/// These tests pin the decision layer that replaced it. They cover the parts a
/// user notices when they get them wrong: "off" that still plays a sound,
/// "party" that fires every single time and stops feeling like a reward, a
/// particle toggle that does nothing for the selected effect, and a stored
/// preference from a newer build that refuses to load.
@Suite("Celebration preferences")
internal struct CelebrationPreferencesTests {

    // MARK: - The master switch

    @Test("disabled zeroes the chance regardless of how high the base was")
    internal func disabledZeroesChance() {
        var prefs = CelebrationPreferences.default
        prefs.isEnabled = false
        // 0.85 is what the manager computes on a 10-message milestone with a
        // long response — the highest it ever goes.
        #expect(prefs.adjustedChance(0.85) == 0)
        #expect(prefs.adjustedChance(1.0) == 0)
    }

    @Test("disabled draws no particles even with the toggle on and confetti picked")
    internal func disabledDrawsNoParticles() {
        var prefs = CelebrationPreferences.default
        prefs.isEnabled = false
        #expect(prefs.style == .confetti)
        #expect(prefs.particlesEnabled)
        #expect(!prefs.shouldDrawParticles)
        #expect(prefs.resolvedParticleCount == 0)
    }

    // MARK: - Intensity

    @Test("party scales the odds up but never past certainty")
    internal func partyChanceIsClamped() {
        var prefs = CelebrationPreferences.default
        prefs.intensity = .party
        // Unclamped this is 1.7. A "random" reward that fires every time is no
        // longer a variable-ratio schedule, which is the entire mechanism.
        #expect(prefs.adjustedChance(0.85) == 1.0)
        // Below the ceiling it really does double.
        #expect(abs(prefs.adjustedChance(0.2) - 0.4) < 0.0001)
    }

    @Test("subtle reduces the odds without reaching zero")
    internal func subtleReducesChance() {
        var prefs = CelebrationPreferences.default
        prefs.intensity = .subtle
        let chance = prefs.adjustedChance(0.15)
        #expect(chance < 0.15)
        #expect(chance > 0)
    }

    @Test("a negative base chance cannot become a negative probability")
    internal func negativeBaseIsClamped() {
        #expect(CelebrationPreferences.default.adjustedChance(-1) == 0)
    }

    @Test("every intensity throttles — party included")
    internal func everyIntensityThrottles() {
        for intensity in CelebrationIntensity.allCases {
            // A zero interval would let back-to-back celebrations stack on one
            // stage, each cancelling the other's performance mid-beat.
            #expect(intensity.throttleInterval > 0)
            #expect(intensity.particleCount > 0)
        }
        #expect(CelebrationIntensity.subtle.throttleInterval
                > CelebrationIntensity.party.throttleInterval)
        #expect(CelebrationIntensity.party.particleCount
                > CelebrationIntensity.subtle.particleCount)
    }

    @Test("particle count follows the selected intensity")
    internal func particleCountFollowsIntensity() {
        var prefs = CelebrationPreferences.default
        prefs.intensity = .party
        #expect(prefs.resolvedParticleCount == CelebrationIntensity.party.particleCount)
        prefs.intensity = .subtle
        #expect(prefs.resolvedParticleCount == CelebrationIntensity.subtle.particleCount)
    }

    // MARK: - Particles vs. style

    @Test("the particle toggle only applies to styles that draw particles")
    internal func particlesGatedOnStyle() {
        var prefs = CelebrationPreferences.default
        prefs.particlesEnabled = true

        prefs.style = .confetti
        #expect(prefs.shouldDrawParticles)

        // The monkey and the card don't draw particles, so honoring the toggle
        // for them would put confetti behind an effect that never asked for it.
        prefs.style = .monkey
        #expect(!prefs.shouldDrawParticles)
        prefs.style = .card
        #expect(!prefs.shouldDrawParticles)
    }

    @Test("turning particles off leaves the effect selected")
    internal func particlesOffKeepsStyle() {
        var prefs = CelebrationPreferences.default
        prefs.particlesEnabled = false
        #expect(!prefs.shouldDrawParticles)
        // Still enabled and still confetti — the user removed the dots, not the
        // celebration.
        #expect(prefs.isEnabled)
        #expect(prefs.style == .confetti)
    }

    // MARK: - Stored value decoding

    @Test("an unknown stored style downgrades to confetti instead of failing")
    internal func unknownStyleDowngrades() {
        // A preference written by a newer build, or a hand-edited defaults
        // plist. Refusing to load would leave the section blank.
        #expect(CelebrationStyle(storedValue: "hologram") == .confetti)
        #expect(CelebrationStyle(storedValue: nil) == .confetti)
        #expect(CelebrationStyle(storedValue: "") == .confetti)
        #expect(CelebrationStyle(storedValue: "monkey") == .monkey)
    }

    @Test("an unknown stored intensity falls back to normal")
    internal func unknownIntensityDowngrades() {
        #expect(CelebrationIntensity(storedValue: "deafening") == .normal)
        #expect(CelebrationIntensity(storedValue: nil) == .normal)
        #expect(CelebrationIntensity(storedValue: "party") == .party)
    }

    @Test("every style and intensity round-trips through its raw value")
    internal func rawValuesRoundTrip() {
        for style in CelebrationStyle.allCases {
            #expect(CelebrationStyle(storedValue: style.rawValue) == style)
            #expect(!style.label.isEmpty)
            #expect(!style.detail.isEmpty)
        }
        for intensity in CelebrationIntensity.allCases {
            #expect(CelebrationIntensity(storedValue: intensity.rawValue) == intensity)
            #expect(!intensity.label.isEmpty)
        }
    }

    // MARK: - Sound

    @Test("no sound plays when celebrations are off, whatever the sound setting")
    internal func disabledPlaysNoSound() {
        var prefs = CelebrationPreferences.default
        prefs.isEnabled = false
        prefs.soundEnabled = true
        prefs.sound = .hero
        // "Off" has to mean silent too — a celebration that is invisible but
        // still audible is the worst of both.
        #expect(prefs.soundToPlay() == nil)
    }

    @Test("no sound plays when sound is off")
    internal func soundDisabledPlaysNothing() {
        var prefs = CelebrationPreferences.default
        prefs.soundEnabled = false
        prefs.sound = .glass
        #expect(prefs.soundToPlay() == nil)
    }

    @Test("a chosen sound is the sound that plays")
    internal func chosenSoundPlays() {
        var prefs = CelebrationPreferences.default
        prefs.sound = .submarine
        #expect(prefs.soundToPlay() == .submarine)
    }

    @Test("random resolves to a concrete sound, never to itself")
    internal func randomResolvesToConcrete() {
        var prefs = CelebrationPreferences.default
        prefs.sound = .random
        for _ in 0..<40 {
            let played = prefs.soundToPlay()
            // `.random` reaching the player would find no `systemSoundName` and
            // silently play nothing — a celebration that is randomly silent.
            #expect(played != .random)
            #expect(played != nil)
            #expect(CelebrationSound.randomPool.contains(played ?? .random))
        }
    }

    @Test("random draws more than one distinct sound")
    internal func randomActuallyVaries() {
        var prefs = CelebrationPreferences.default
        prefs.sound = .random
        // Guards against a "random" that always returns the pool's first
        // element, which is indistinguishable from a fixed choice in use.
        let drawn = Set((0..<80).compactMap { _ in prefs.soundToPlay() })
        #expect(drawn.count > 1)
    }

    @Test("a concrete sound resolves to itself")
    internal func concreteSoundIsIdempotent() {
        for sound in CelebrationSound.selectableSounds {
            #expect(sound.resolved() == sound)
        }
    }

    @Test("every selectable sound names a real system sound file")
    internal func selectableSoundsExist() {
        for sound in CelebrationSound.selectableSounds {
            let name = sound.systemSoundName
            #expect(name != nil)
            // `NSSound(named:)` resolves from /System/Library/Sounds, so a typo'd
            // case is a silently-silent celebration. Checking the file rather
            // than constructing NSSound keeps this runnable headless.
            let path = "/System/Library/Sounds/\(name ?? "").aiff"
            #expect(FileManager.default.fileExists(atPath: path),
                    "no system sound at \(path) for case .\(sound.rawValue)")
        }
    }

    @Test("random has no sound name of its own")
    internal func randomHasNoName() {
        // It is a strategy, not a sound; a name here would bypass `resolved()`.
        #expect(CelebrationSound.random.systemSoundName == nil)
        #expect(!CelebrationSound.selectableSounds.contains(.random))
        #expect(!CelebrationSound.randomPool.contains(.random))
    }

    @Test("an unknown stored sound falls back to random")
    internal func unknownSoundDowngrades() {
        #expect(CelebrationSound(storedValue: "airhorn") == .random)
        #expect(CelebrationSound(storedValue: nil) == .random)
        #expect(CelebrationSound(storedValue: "purr") == .purr)
    }

    @Test("every sound round-trips and has a label")
    internal func soundsRoundTrip() {
        for sound in CelebrationSound.allCases {
            #expect(CelebrationSound(storedValue: sound.rawValue) == sound)
            #expect(!sound.label.isEmpty)
        }
        // Labels must be unique or the picker shows two identical rows.
        let labels = CelebrationSound.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    // MARK: - Defaults

    @Test("the default preserves the behavior that shipped")
    internal func defaultMatchesShippedBehavior() {
        let prefs = CelebrationPreferences.default
        // Existing users must not have celebrations silently disappear because
        // the feature became configurable.
        #expect(prefs.isEnabled)
        #expect(prefs.style == .confetti)
        #expect(prefs.intensity == .normal)
        #expect(prefs.soundEnabled)
        // The shipped sound was a random pick each time, so that has to stay the
        // default rather than freezing on whichever case is listed first.
        #expect(prefs.sound == .random)
        // 60 particles at normal is exactly what the hard-coded call passed.
        #expect(prefs.resolvedParticleCount == 60)
        // …and 2s is the throttle the manager hard-coded.
        #expect(prefs.intensity.throttleInterval == 2.0)
        #expect(prefs.intensity.chanceMultiplier == 1.0)
    }

    // MARK: - Reading from UserDefaults

    @Test("absent keys read as the defaults, not as false")
    internal func absentKeysReadAsDefaults() throws {
        // A fresh install has no keys at all. `bool(forKey:)` would return false
        // for the two toggles, which silently ships celebrations off.
        let defaults = try #require(UserDefaults(suiteName: "portal.tests.celebrations.absent"))
        for key in Self.allKeys { defaults.removeObject(forKey: key) }
        defer { for key in Self.allKeys { defaults.removeObject(forKey: key) } }

        let prefs = SettingsViewModel.storedCelebrationPreferences(defaults)
        #expect(prefs == CelebrationPreferences.default)
    }

    @Test("stored values are read back exactly")
    internal func storedValuesRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "portal.tests.celebrations.stored"))
        for key in Self.allKeys { defaults.removeObject(forKey: key) }
        defer { for key in Self.allKeys { defaults.removeObject(forKey: key) } }

        defaults.set(false, forKey: SettingsViewModel.celebrationsEnabledKey)
        defaults.set("monkey", forKey: SettingsViewModel.celebrationStyleKey)
        defaults.set("party", forKey: SettingsViewModel.celebrationIntensityKey)
        defaults.set(false, forKey: SettingsViewModel.celebrationParticlesKey)
        defaults.set(false, forKey: SettingsViewModel.celebrationSoundKey)
        defaults.set("submarine", forKey: SettingsViewModel.celebrationSoundNameKey)

        let prefs = SettingsViewModel.storedCelebrationPreferences(defaults)
        #expect(!prefs.isEnabled)
        #expect(prefs.style == .monkey)
        #expect(prefs.intensity == .party)
        #expect(!prefs.particlesEnabled)
        #expect(!prefs.soundEnabled)
        // The chosen sound is remembered even though sound is currently off, so
        // switching the toggle back on restores the pick instead of resetting it.
        #expect(prefs.sound == .submarine)
    }

    /// Read through a `suiteName` domain, never `.standard`: the app's real
    /// preferences are the user's, and a test that clears keys in the standard
    /// domain resets their actual settings.
    private static let allKeys = [
        SettingsViewModel.celebrationsEnabledKey,
        SettingsViewModel.celebrationStyleKey,
        SettingsViewModel.celebrationIntensityKey,
        SettingsViewModel.celebrationParticlesKey,
        SettingsViewModel.celebrationSoundKey,
        SettingsViewModel.celebrationSoundNameKey,
    ]
}

/// The choreography the user asked for, in order: it goes up, holds the gun,
/// says its line, drops the gun, shakes, and goes back.
///
/// Worth testing rather than eyeballing because the timeline is shared with the
/// manager's auto-clear timer. If the beats outlast
/// `CelebrationManager.performanceDuration`, the stage is torn down mid-beat and
/// the effect vanishes instead of exiting — a bug that looks like a rendering
/// glitch and is actually arithmetic.
@Suite("Celebration choreography")
internal struct CelebrationBeatTests {

    @Test("the sequence performs the requested order")
    internal func sequenceOrder() {
        #expect(CelebrationBeat.sequence == [.rise, .settle, .raise, .speak, .lower, .shake, .exit])
        // .offstage is a resting pose, not a step: including it would stall the
        // timeline on a zero-length beat.
        #expect(!CelebrationBeat.sequence.contains(.offstage))
    }

    @Test("the manager holds the stage for at least the full performance")
    internal func performanceOutlastsChoreography() {
        #expect(CelebrationManager.performanceDuration >= CelebrationBeat.totalDuration)
    }

    @Test("every scheduled beat has a positive duration")
    internal func beatsAdvance() {
        for beat in CelebrationBeat.sequence {
            // A zero-length beat is unreachable via `beat(at:)`, so the pose
            // would never be drawn.
            #expect(beat.duration > 0)
        }
        #expect(CelebrationBeat.offstage.duration == 0)
    }

    @Test("the beat at a given elapsed time is the one scheduled there")
    internal func beatLookupWalksTheTimeline() {
        for beat in CelebrationBeat.sequence {
            guard let start = CelebrationBeat.startTime(of: beat) else {
                Issue.record("\(beat) is in the sequence but has no start time")
                continue
            }
            // Just inside the beat's own window, from both ends.
            #expect(CelebrationBeat.beat(at: start + 0.001) == beat)
            #expect(CelebrationBeat.beat(at: start + beat.duration - 0.001) == beat)
        }
    }

    @Test("before the start and after the end nothing is on stage")
    internal func outOfRangeIsOffstage() {
        // Rendered early or held late, the stage draws nothing rather than
        // freezing on the first or last pose.
        #expect(CelebrationBeat.beat(at: -1) == .offstage)
        #expect(CelebrationBeat.beat(at: CelebrationBeat.totalDuration) == .offstage)
        #expect(CelebrationBeat.beat(at: CelebrationBeat.totalDuration + 10) == .offstage)
        #expect(CelebrationBeat.startTime(of: .offstage) == nil)
    }

    @Test("elapsed 0 starts the rise")
    internal func startsWithRise() {
        #expect(CelebrationBeat.beat(at: 0) == .rise)
        #expect(CelebrationBeat.startTime(of: .rise) == 0)
    }

    @Test("the gun goes up for raise and speak, and comes down after")
    internal func aimingSpansRaiseAndSpeak() {
        #expect(CelebrationBeat.raise.isAiming)
        #expect(CelebrationBeat.speak.isAiming)
        // "then drop the gun": lower and everything after must not be aiming,
        // or the shake happens with the pistol still up.
        #expect(!CelebrationBeat.lower.isAiming)
        #expect(!CelebrationBeat.shake.isAiming)
        #expect(!CelebrationBeat.exit.isAiming)
        // The arm actually moves, and only while aiming.
        #expect(CelebrationBeat.raise.armAngle < 0)
        #expect(CelebrationBeat.lower.armAngle == 0)
        #expect(CelebrationBeat.rise.armAngle == 0)
    }

    @Test("the shake follows the lower, so the gun is down before it shakes")
    internal func shakeFollowsLower() throws {
        let lower = try #require(CelebrationBeat.startTime(of: .lower))
        let shake = try #require(CelebrationBeat.startTime(of: .shake))
        #expect(shake > lower)
        #expect(CelebrationBeat.shake.isShaking)
        #expect(!CelebrationBeat.raise.isShaking)
    }

    @Test("the line is on screen for exactly the speak beat")
    internal func onlySpeakSpeaks() {
        for beat in CelebrationBeat.allCases {
            #expect(beat.isSpeaking == (beat == .speak))
        }
    }

    @Test("the character is in frame from the rise through the shake, out on exit")
    internal func verticalOffsetBracketsThePerformance() {
        // 1 is fully below the frame, 0 is fully in frame.
        #expect(CelebrationBeat.offstage.verticalOffsetFraction == 1.0)
        #expect(CelebrationBeat.exit.verticalOffsetFraction == 1.0)
        for beat in [CelebrationBeat.rise, .settle, .raise, .speak, .lower, .shake] {
            #expect(beat.verticalOffsetFraction == 0.0)
        }
    }
}

/// The event payloads the presentation site now reads. Before, both accessors'
/// worth of information was thrown away at `ContentView.swift:84`.
@Suite("Celebration event payloads")
@MainActor
internal struct CelebrationEventTests {

    @Test("a milestone carries its badge and message")
    internal func milestoneExposesPayload() {
        let event = CelebrationManager.CelebrationEvent.milestone(
            level: .gold, message: "Skill unlocked: graphify"
        )
        #expect(event.message == "Skill unlocked: graphify")
        #expect(event.badge == "🥇")
    }

    @Test("a plain celebration has an occasion and no badge")
    internal func confettiExposesOccasion() {
        let event = CelebrationManager.CelebrationEvent.confetti(occasion: "Nice work!")
        #expect(event.message == "Nice work!")
        #expect(event.badge == nil)
    }

    @Test("ids distinguish events so the stage restarts rather than resuming")
    internal func idsAreDistinct() {
        // ContentView keys the stage on this id; colliding ids would let a new
        // celebration inherit the previous one's elapsed time and appear
        // already mid-exit.
        let first = CelebrationManager.CelebrationEvent.confetti(occasion: "one")
        let second = CelebrationManager.CelebrationEvent.confetti(occasion: "two")
        #expect(first.id != second.id)
        #expect(CelebrationManager.CelebrationEvent.milestone(level: .gold, message: "x").id
                != CelebrationManager.CelebrationEvent.milestone(level: .bronze, message: "x").id)
    }

    @Test("every milestone level has a distinct badge")
    internal func milestoneBadgesAreDistinct() {
        let badges = [
            CelebrationManager.MilestoneLevel.bronze,
            .silver, .gold, .epic,
        ].map(\.rawValue)
        #expect(Set(badges).count == badges.count)
    }
}
