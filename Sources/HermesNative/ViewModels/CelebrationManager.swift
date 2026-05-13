import SwiftUI
import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "CelebrationManager")

/// Manages positive reinforcement celebrations using variable-ratio reward
/// scheduling — the most effective reinforcement pattern for habit formation.
/// Celebrations are unpredictable but frequent enough to feel rewarding.
@MainActor
final class CelebrationManager: ObservableObject {
    static let shared = CelebrationManager()

    @Published var activeCelebration: CelebrationEvent?

    private let soundEffects = SoundEffects()
    private var sessionMessageCounts: [String: Int] = [:]
    private var totalSkillsInstalled: Int = 0
    private var lastCelebrationDate: Date?

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
    }

    enum MilestoneLevel: String {
        case bronze = "🥉"
        case silver = "🥈"
        case gold = "🥇"
        case epic = "🏆"
    }

    private init() {}

    // MARK: - Triggers

    /// Call when a response stream completes.
    func onResponseComplete(sessionID: String, duration: TimeInterval) {
        let count = (sessionMessageCounts[sessionID] ?? 0) + 1
        sessionMessageCounts[sessionID] = count

        // Variable-ratio reward: celebrate randomly, more likely after longer waits
        let baseChance = 0.15
        let durationBonus = min(duration / 10.0, 0.2) // up to +20% for long responses
        let milestoneBonus = count.isMultiple(of: 10) ? 0.5 : 0
        let chance = baseChance + durationBonus + milestoneBonus

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

    // MARK: - Private

    private func celebrate(_ event: CelebrationEvent) {
        // Throttle: max one celebration per 2 seconds
        if let last = lastCelebrationDate, Date().timeIntervalSince(last) < 2.0 {
            return
        }
        lastCelebrationDate = Date()

        activeCelebration = event
        soundEffects.playSuccess()

        // Auto-clear after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.activeCelebration = nil
        }
    }
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
