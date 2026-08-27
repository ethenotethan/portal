import Foundation

/// Which visual performs a celebration.
///
/// `CelebrationManager` decides *when* to celebrate (variable-ratio schedule,
/// throttle, per-trigger rules); a style decides *what that looks like*. The two
/// were fused before: the manager built `.confetti` / `.milestone` events and
/// `ContentView` ignored the event entirely, hard-rendering 60 confetti
/// particles — so the milestone level and its message ("Skill unlocked: X") were
/// computed and thrown away, and there was no way to add a second look without
/// editing the presentation site.
///
/// Adding a style is a case here plus a branch in `CelebrationStage`. Unknown
/// raw values decode to `.confetti` so a persisted preference from a newer build
/// downgrades instead of crashing.
internal enum CelebrationStyle: String, CaseIterable, Codable, Sendable {
    /// The original: particles burst upward and fall under gravity.
    case confetti
    /// A monkey rises into frame, raises a pistol, says "good job", lowers it,
    /// shakes, and drops back out.
    case monkey
    /// The milestone level and message the manager already computes, presented
    /// as a card that rises and falls. No particles.
    case card

    internal var label: String {
        switch self {
        case .confetti: return "Confetti"
        case .monkey: return "Monkey"
        case .card: return "Milestone card"
        }
    }

    internal var detail: String {
        switch self {
        case .confetti: return "Particles burst upward and fall."
        case .monkey: return "A monkey rises, salutes with a pistol, and drops back out."
        case .card: return "A card with the milestone and its message."
        }
    }

    /// Styles that draw particles. The particle toggle only applies to these,
    /// so the UI can disable it rather than offering a control that does
    /// nothing for the selected style.
    internal var usesParticles: Bool { self == .confetti }

    internal init(storedValue: String?) {
        self = storedValue.flatMap(CelebrationStyle.init(rawValue:)) ?? .confetti
    }
}

/// How much celebration happens. Scales the manager's random chance, not just
/// the visuals — "subtle" means fewer celebrations, not quieter ones, because a
/// user who finds them intrusive wants them to occur less often.
internal enum CelebrationIntensity: String, CaseIterable, Codable, Sendable {
    case subtle
    case normal
    case party

    internal var label: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .party: return "Party"
        }
    }

    /// Multiplier on the trigger probability.
    internal var chanceMultiplier: Double {
        switch self {
        case .subtle: return 0.4
        case .normal: return 1.0
        case .party: return 2.0
        }
    }

    /// Particle count for styles that draw them.
    internal var particleCount: Int {
        switch self {
        case .subtle: return 24
        case .normal: return 60
        case .party: return 140
        }
    }

    /// Minimum gap between celebrations. Party still throttles — back-to-back
    /// overlays would fight over the same stage.
    internal var throttleInterval: TimeInterval {
        switch self {
        case .subtle: return 8.0
        case .normal: return 2.0
        case .party: return 1.0
        }
    }

    internal init(storedValue: String?) {
        self = storedValue.flatMap(CelebrationIntensity.init(rawValue:)) ?? .normal
    }
}

/// Which sound a celebration plays.
///
/// Backed by the macOS system sounds in `/System/Library/Sounds`, which every
/// install has — no bundled audio, so a sound cannot fail to load because an
/// asset did not resolve. `random` preserves the shipped behavior (a
/// different pick each time) as an explicit choice rather than the only one.
///
/// On iOS these names have no meaning: there is no `NSSound` and no system
/// sound by these names, so the platform plays a haptic instead and the picker
/// is hidden. The enum is still shared because the preference persists across
/// devices and must round-trip on both.
internal enum CelebrationSound: String, CaseIterable, Codable, Sendable {
    /// A different one of the curated sounds on each celebration — the original
    /// behavior.
    case random
    case hero
    case glass
    case funk
    case blow
    case purr
    case ping
    case pop
    case tink
    case submarine

    internal var label: String {
        switch self {
        case .random: return "Random"
        case .hero: return "Hero"
        case .glass: return "Glass"
        case .funk: return "Funk"
        case .blow: return "Blow"
        case .purr: return "Purr"
        case .ping: return "Ping"
        case .pop: return "Pop"
        case .tink: return "Tink"
        case .submarine: return "Submarine"
        }
    }

    /// The `NSSound(named:)` name, or nil for `.random`, which has none of its
    /// own and resolves through `randomPool` instead.
    internal var systemSoundName: String? {
        self == .random ? nil : label
    }

    /// Every case that names an actual sound.
    internal static var selectableSounds: [CelebrationSound] {
        allCases.filter { $0 != .random }
    }

    /// What `.random` draws from. The shipped list, minus "Funk" and "Blow"
    /// being the only two of five that aren't celebratory — kept anyway, since
    /// removing them would silently change a behavior a user may have grown
    /// used to, and they are individually selectable now regardless.
    internal static let randomPool: [CelebrationSound] = [.hero, .glass, .funk, .blow, .purr]

    /// The sound to actually play for this preference: `.random` resolves to a
    /// member of `randomPool`, everything else is itself.
    internal func resolved() -> CelebrationSound {
        guard self == .random else { return self }
        return Self.randomPool.randomElement() ?? .hero
    }

    internal init(storedValue: String?) {
        self = storedValue.flatMap(CelebrationSound.init(rawValue:)) ?? .random
    }
}

/// The user's celebration configuration, resolved from persisted values.
///
/// A value type so the decision logic is testable without a live
/// `UserDefaults`, a running app, or the `CelebrationManager` singleton.
internal struct CelebrationPreferences: Equatable, Sendable {
    /// Master switch. Off means nothing is ever presented and no sound plays —
    /// the manager returns before scheduling, so this is not merely a hidden
    /// overlay.
    internal var isEnabled: Bool
    internal var style: CelebrationStyle
    internal var intensity: CelebrationIntensity
    /// Particles, controlled separately from the style so the animated dots can
    /// be switched off while keeping the rest of the celebration.
    internal var particlesEnabled: Bool
    /// Whether a sound (macOS) or haptic (iOS) accompanies a celebration.
    internal var soundEnabled: Bool
    /// Which sound. Ignored when `soundEnabled` is false.
    internal var sound: CelebrationSound

    internal static let `default` = CelebrationPreferences(
        isEnabled: true,
        style: .confetti,
        intensity: .normal,
        particlesEnabled: true,
        soundEnabled: true,
        sound: .random
    )

    /// The sound to play right now, or nil when none should be. One place to ask
    /// so the two gates (`isEnabled`, `soundEnabled`) and the `.random` draw
    /// can't be applied inconsistently by different callers.
    internal func soundToPlay() -> CelebrationSound? {
        guard isEnabled, soundEnabled else { return nil }
        return sound.resolved()
    }

    /// Whether particles should actually be drawn: the toggle only has meaning
    /// for a style that draws them, and never fires when celebrations are off.
    internal var shouldDrawParticles: Bool {
        isEnabled && particlesEnabled && style.usesParticles
    }

    /// Particle count for this configuration, or 0 when none should be drawn.
    /// Callers can pass this straight to a burst without repeating the gating.
    internal var resolvedParticleCount: Int {
        shouldDrawParticles ? intensity.particleCount : 0
    }

    /// Apply intensity to a computed probability, clamped to a valid range.
    ///
    /// Clamping matters at `.party`: the manager's own chance already reaches
    /// 0.85 on a 10-message milestone, and 2× that is >1, which would make a
    /// "random" reward fire every single time and destroy the variable-ratio
    /// schedule the whole mechanism depends on.
    internal func adjustedChance(_ base: Double) -> Double {
        guard isEnabled else { return 0 }
        return min(max(base * intensity.chanceMultiplier, 0), 1)
    }
}
