import Foundation

/// SM-2 spaced repetition algorithm implementation.
///
/// The SM-2 algorithm adjusts card review intervals based on self-graded recall quality.
/// Lower quality → shorter intervals and lower ease factor.
/// Higher quality → exponentially growing intervals.
///
/// Reference: SuperMemo SM-2 (Wozniak, 1990)
enum SRSEngine {
    /// Minimum ease factor a card can decay to.
    static let minEaseFactor: Double = 1.3

    /// Default ease factor for new cards.
    static let defaultEaseFactor: Double = 2.5

    /// Number of seconds in one day.
    static let oneDay: TimeInterval = 86_400

    // MARK: - Core Algorithm

    /// Calculate the next SRS state given a quality score and current state.
    ///
    /// Quality mapping (self-grade):
    /// - 0 = "Didn't know" (blackout)
    /// - 2 = "Almost" (recalled with difficulty)
    /// - 4 = "Good" (correct with hesitation)
    /// - 5 = "Knew it" (perfect recall)
    static func calculate(quality: Int, state: SRSState) -> SRSState {
        var next = state
        next.reviewCount += 1
        next.lastReviewedAt = Date()
        next.lastQuality = quality

        if quality < 3 {
            // Failed recall — reset the card
            next.repetitions = 0
            next.interval = 1
        } else {
            // Successful recall — grow the interval
            switch next.repetitions {
            case 0:
                next.interval = 1
            case 1:
                next.interval = 6
            default:
                next.interval = round(next.interval * next.easeFactor)
            }
            next.repetitions += 1
        }

        // Update ease factor using SM-2 formula:
        // EF' = EF + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))
        let q = Double(quality)
        let delta = 0.1 - (5.0 - q) * (0.08 + (5.0 - q) * 0.02)
        next.easeFactor = max(minEaseFactor, next.easeFactor + delta)

        // Schedule next review
        next.nextReviewDate = Date().addingTimeInterval(next.interval * oneDay)

        return next
    }

    /// Convenience overload accepting SRSQuality enum.
    static func calculate(quality: SRSQuality, state: SRSState) -> SRSState {
        calculate(quality: quality.rawValue, state: state)
    }

    // MARK: - Queries

    /// Check if a card is due for review.
    static func isDue(state: SRSState) -> Bool {
        state.isDue
    }

    /// Days until a card is due. 0 = due now or overdue, negative = overdue by N days.
    static func daysUntilDue(state: SRSState) -> Int {
        let seconds = state.nextReviewDate.timeIntervalSinceNow
        return Int(round(seconds / oneDay))
    }

    /// Human-readable description of when a card is next due.
    static func dueDescription(state: SRSState) -> String {
        let days = daysUntilDue(state: state)
        switch days {
        case ...(-1): return "\(-days)d overdue"
        case 0: return "Due now"
        case 1: return "Tomorrow"
        case 2...6: return "In \(days) days"
        case 7...13: return "In 1 week"
        case 14...30: return "In \(days / 7) weeks"
        case 31...365: return "In \(days / 30) months"
        default: return ">1 year"
        }
    }
}
