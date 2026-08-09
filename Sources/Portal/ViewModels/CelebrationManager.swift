import SwiftUI
import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CelebrationManager")

/// Manages positive reinforcement celebrations using variable-ratio reward
/// scheduling — the most effective reinforcement pattern for habit formation.
/// Celebrations are unpredictable but frequent enough to feel rewarding.
@MainActor
final class CelebrationManager: ObservableObject {
    static let shared = CelebrationManager()

    @Published var activeCelebration: CelebrationEvent?

    /// The user's configuration. Owned here (not read from `SettingsViewModel`)
    /// because the manager is a `ViewModels` type that the trigger call sites
    /// reach through `.shared`, with no settings instance in hand;
    /// `SettingsViewModel` pushes changes in via `apply(_:)`.
    ///
    /// Seeded from `UserDefaults` rather than defaulted, so a user who turned
    /// celebrations off does not get one fired at them in the window between
    /// process start and `SettingsViewModel.init` finishing.
    @Published internal private(set) var preferences: CelebrationPreferences =
        SettingsViewModel.storedCelebrationPreferences()

    private let soundEffects = SoundEffects()
    private var sessionMessageCounts: [String: Int] = [:]
    private var totalSkillsInstalled: Int = 0
    private var lastCelebrationDate: Date?
    /// Cancels the pending auto-clear when a later celebration replaces this
    /// one. Without it, the earlier event's 3s timer fires mid-performance and
    /// blanks the stage — visible at `.party`, whose throttle is 1s.
    private var clearWorkItem: DispatchWorkItem?

    // MARK: - Events

    enum CelebrationEvent: Identifiable {
        case confetti(occasion: String)
        case milestone(level: MilestoneLevel, message: String)

        var id: String {
            switch self {
            case .confetti(let o): return "confetti-\(o)"
            case .milestone(let l, let m): return "milestone-\(l.rawValue)-\(m)"
            }
        }

        /// The line the effect speaks or captions. Every event already carried
        /// one; the old presentation site read neither, so a milestone's message
        /// was computed and dropped.
        internal var message: String {
            switch self {
            case .confetti(let occasion): return occasion
            case .milestone(_, let message): return message
            }
        }

        /// The badge for a milestone, absent for a plain celebration.
        internal var badge: String? {
            switch self {
            case .confetti: return nil
            case .milestone(let level, _): return level.rawValue
            }
        }
    }

    enum MilestoneLevel: String {
        case bronze = "🥉"
        case silver = "🥈"
        case gold = "🥇"
        case epic = "🏆"
    }

    private init() {}

    // MARK: - Configuration

    /// Adopt a new configuration. Called by `SettingsViewModel` at init and on
    /// every change to a celebration setting.
    ///
    /// Turning celebrations off clears anything on screen immediately: a user
    /// who flips the switch mid-performance means "not this one either", and
    /// leaving it to run out looks like the toggle did nothing.
    internal func apply(_ preferences: CelebrationPreferences) {
        self.preferences = preferences
        if !preferences.isEnabled {
            clearWorkItem?.cancel()
            clearWorkItem = nil
            activeCelebration = nil
        }
    }

    /// Fire the currently-configured effect on demand, so the Settings row can
    /// preview it. Bypasses the throttle and the random schedule — the user
    /// asked for exactly one — but not the master switch.
    internal func preview() {
        guard preferences.isEnabled else { return }
        lastCelebrationDate = nil
        celebrate(.milestone(level: .gold, message: "Good job"))
    }

    // MARK: - Triggers

    /// Call when a response stream completes.
    func onResponseComplete(sessionID: String, duration: TimeInterval) {
        let count = (sessionMessageCounts[sessionID] ?? 0) + 1
        sessionMessageCounts[sessionID] = count

        // Variable-ratio reward: celebrate randomly, more likely after longer waits
        let baseChance = 0.15
        let durationBonus = min(duration / 10.0, 0.2) // up to +20% for long responses
        let milestoneBonus = count.isMultiple(of: 10) ? 0.5 : 0
        // Intensity scales the odds, not the visuals: someone who finds these
        // intrusive wants fewer of them, not smaller ones. Returns 0 when
        // celebrations are off, so the random draw can never succeed.
        let chance = preferences.adjustedChance(baseChance + durationBonus + milestoneBonus)

        if Double.random(in: 0...1) < chance {
            if count.isMultiple(of: 10) {
                celebrate(.milestone(level: .gold, message: "\(count) messages in this session!"))
            } else if duration > 8 {
                celebrate(.confetti(occasion: "Deep thought complete"))
            } else {
                celebrate(.confetti(occasion: "Nice work!"))
            }
        }
    }

    /// Call when a skill is successfully installed.
    func onSkillInstalled(name: String) {
        totalSkillsInstalled += 1
        let level: MilestoneLevel
        switch totalSkillsInstalled {
        case 1: level = .bronze
        case 5: level = .silver
        case 10: level = .gold
        case 25: level = .epic
        default: level = .bronze
        }
        celebrate(.milestone(level: level, message: "Skill unlocked: \(name)"))
    }

    /// Call on first message of a new session — "fresh start" dopamine hit.
    func onFirstMessage(sessionID: String) {
        sessionMessageCounts[sessionID] = 1
        celebrate(.confetti(occasion: "New session started!"))
    }

    /// Call when a CRON job completes successfully.
    func onCronSuccess(jobName: String) {
        celebrate(.confetti(occasion: "\(jobName) completed"))
    }

    /// Call when the gateway detects an affectionate reaction (hearts etc.).
    /// Always celebrates — the gateway already decided the moment deserves it.
    func onReaction(occasion: String) {
        celebrate(.confetti(occasion: occasion))
    }

    // MARK: - Private

    private func celebrate(_ event: CelebrationEvent) {
        // The master switch short-circuits here rather than in the overlay, so
        // "off" also means no sound and no state churn — not merely a hidden
        // animation. The unconditional triggers (`onSkillInstalled`,
        // `onFirstMessage`, `onCronSuccess`, `onReaction`) never consult
        // `adjustedChance`, so this is the only gate they pass through.
        guard preferences.isEnabled else { return }

        // Throttle, at the interval the chosen intensity asks for.
        let throttle = preferences.intensity.throttleInterval
        if let last = lastCelebrationDate, Date().timeIntervalSince(last) < throttle {
            return
        }
        lastCelebrationDate = Date()

        activeCelebration = event
        if preferences.soundEnabled {
            soundEffects.playSuccess()
        }

        // Auto-clear after the performance, cancelling any earlier pending
        // clear so a superseded event's timer can't blank this one mid-run.
        clearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.activeCelebration = nil
            self?.clearWorkItem = nil
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.performanceDuration, execute: work)
    }

    /// How long a celebration stays on screen. Must outlast the longest style's
    /// choreography — the monkey's beats run to `CelebrationBeat.totalDuration`
    /// — or the stage is torn down mid-performance.
    nonisolated internal static let performanceDuration: TimeInterval = 3.4
}

// MARK: - Sound Effects

@MainActor
private final class SoundEffects {
    #if os(macOS)
    private var sound: NSSound?
    #endif

    func playSuccess() {
        #if os(macOS)
        // Use a pleasant built-in macOS sound
        let names = ["Hero", "Glass", "Funk", "Blow", "Purr"]
        if let name = names.randomElement(), let s = NSSound(named: name) {
            s.play()
        }
        #elseif os(iOS)
        // Light haptic tap for success
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}
