import Foundation

/// One step of a celebration's choreography.
///
/// The stage is generic over styles, so the sequence of moves has to be data
/// rather than a chain of nested `withAnimation` completion handlers. Keeping it
/// as a timeline of beats means the phase at any elapsed time is a pure lookup —
/// testable without rendering anything, and impossible to desynchronize from the
/// auto-clear timer, which is what "the animation cut off halfway" looks like.
internal enum CelebrationBeat: String, CaseIterable, Sendable {
    /// Off-stage, below the frame. The resting state before and after.
    case offstage
    /// Rising into frame.
    case rise
    /// In frame, arm down, settling from the rise.
    case settle
    /// Arm raised, holding the pistol pointed at the viewer.
    case raise
    /// Speaking. The line is on screen.
    case speak
    /// Arm lowered again.
    case lower
    /// Shaking in place.
    case shake
    /// Dropping back out of frame.
    case exit

    /// How long this beat lasts.
    internal var duration: TimeInterval {
        switch self {
        case .offstage: return 0
        case .rise: return 0.45
        case .settle: return 0.15
        case .raise: return 0.35
        case .speak: return 0.95
        case .lower: return 0.3
        case .shake: return 0.5
        case .exit: return 0.4
        }
    }

    /// The order the beats play in, matching the requested choreography: it
    /// pushes up, holds the gun, speaks, drops the gun, shakes, and goes back.
    internal static let sequence: [CelebrationBeat] =
        [.rise, .settle, .raise, .speak, .lower, .shake, .exit]

    /// Total run time of `sequence`.
    ///
    /// `CelebrationManager.performanceDuration` must be at least this, or the
    /// manager clears `activeCelebration` while the stage is still mid-beat and
    /// the effect vanishes rather than exiting.
    internal static var totalDuration: TimeInterval {
        sequence.reduce(0) { $0 + $1.duration }
    }

    /// The beat playing at `elapsed` seconds into the sequence.
    ///
    /// Before the start and after the end this is `.offstage`, so a stage that
    /// is rendered early or held late draws nothing rather than freezing on the
    /// first or last pose.
    internal static func beat(at elapsed: TimeInterval) -> CelebrationBeat {
        guard elapsed >= 0 else { return .offstage }
        var cursor: TimeInterval = 0
        for beat in sequence {
            cursor += beat.duration
            if elapsed < cursor { return beat }
        }
        return .offstage
    }

    /// When `beat` begins, relative to the start of the sequence. `nil` for
    /// `.offstage`, which is not part of the timeline.
    internal static func startTime(of beat: CelebrationBeat) -> TimeInterval? {
        var cursor: TimeInterval = 0
        for candidate in sequence {
            if candidate == beat { return cursor }
            cursor += candidate.duration
        }
        return nil
    }

    // MARK: - Pose

    /// Vertical offset as a fraction of the character's height: 1 is fully
    /// below the frame, 0 is fully in frame.
    internal var verticalOffsetFraction: Double {
        switch self {
        case .offstage, .exit: return 1.0
        case .rise: return 0.0  // animated from 1 → 0 by the transition
        case .settle, .raise, .speak, .lower, .shake: return 0.0
        }
    }

    /// Arm angle in degrees. 0 is hanging down; negative raises the pistol
    /// toward the viewer.
    internal var armAngle: Double {
        switch self {
        case .raise, .speak: return -72
        case .rise, .settle, .lower, .shake, .exit, .offstage: return 0
        }
    }

    /// Whether the pistol is held up rather than at rest. Drives the muzzle
    /// highlight; also what `.lower` turns off, which is the "drop the gun"
    /// beat.
    internal var isAiming: Bool {
        self == .raise || self == .speak
    }

    /// Whether the line is visible.
    internal var isSpeaking: Bool { self == .speak }

    /// Whether the body is shaking.
    internal var isShaking: Bool { self == .shake }
}
