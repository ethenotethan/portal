import Foundation
import Testing
@testable import Portal

@Suite("SRS engine (SM-2)")
internal struct SRSEngineTests {

    private func newState() -> SRSState {
        SRSState(cardID: UUID())
    }

    // MARK: - Failed recall resets the card

    @Test("A sub-3 quality resets repetitions and interval to 1 day")
    internal func failedRecallResets() {
        var state = newState()
        state.repetitions = 5
        state.interval = 40
        let next = SRSEngine.calculate(quality: 1, state: state)
        #expect(next.repetitions == 0)
        #expect(next.interval == 1)
        #expect(next.reviewCount == 1)
        #expect(next.lastQuality == 1)
    }

    @Test("Quality exactly 3 counts as recall, not failure")
    internal func qualityThreeIsRecall() {
        // The boundary: `quality < 3` fails, so 3 must take the success path.
        let next = SRSEngine.calculate(quality: 3, state: newState())
        #expect(next.repetitions == 1)
        #expect(next.interval == 1)
    }

    // MARK: - Interval growth sequence

    @Test("Successful reviews grow the interval 1 → 6 → ease-scaled")
    internal func intervalGrowthSequence() {
        var state = newState()          // repetitions 0, ease 2.5
        state = SRSEngine.calculate(quality: 5, state: state)
        #expect(state.interval == 1)    // first success
        #expect(state.repetitions == 1)

        state = SRSEngine.calculate(quality: 5, state: state)
        #expect(state.interval == 6)    // second success
        #expect(state.repetitions == 2)

        // Third success: interval = round(prev * easeFactor). After two
        // quality-5 reviews ease has grown past 2.5, so 6 * ease rounds to 17.
        let easeAfterTwo = state.easeFactor
        state = SRSEngine.calculate(quality: 5, state: state)
        #expect(state.interval == (6.0 * easeAfterTwo).rounded())
        #expect(state.repetitions == 3)
    }

    // MARK: - Ease factor

    @Test("A perfect review raises the ease factor")
    internal func perfectRaisesEase() {
        // q=5 → delta = 0.1 - 0*(…) = +0.1
        let next = SRSEngine.calculate(quality: 5, state: newState())
        #expect(abs(next.easeFactor - 2.6) < 1e-9)
    }

    @Test("Ease factor never decays below the 1.3 floor")
    internal func easeFloor() {
        var state = newState()
        state.easeFactor = SRSEngine.minEaseFactor
        // A run of low-but-passing grades applies a negative delta each time;
        // ease must clamp at the floor rather than going under.
        for _ in 0..<5 {
            state = SRSEngine.calculate(quality: 3, state: state)
        }
        #expect(state.easeFactor == SRSEngine.minEaseFactor)
    }

    @Test("The SRSQuality overload matches the raw-Int path")
    internal func enumOverloadMatchesRaw() {
        let base = newState()
        let viaEnum = SRSEngine.calculate(quality: .perfect, state: base)
        let viaInt = SRSEngine.calculate(quality: 5, state: base)
        #expect(viaEnum.interval == viaInt.interval)
        #expect(abs(viaEnum.easeFactor - viaInt.easeFactor) < 1e-9)
        #expect(viaEnum.repetitions == viaInt.repetitions)
    }

    // MARK: - Due queries

    @Test("daysUntilDue is negative when overdue, positive when ahead")
    internal func daysUntilDue() {
        var overdue = newState()
        overdue.nextReviewDate = Date().addingTimeInterval(-3 * SRSEngine.oneDay)
        #expect(SRSEngine.daysUntilDue(state: overdue) < 0)

        var ahead = newState()
        ahead.nextReviewDate = Date().addingTimeInterval(7 * SRSEngine.oneDay)
        #expect(SRSEngine.daysUntilDue(state: ahead) == 7)
    }

    @Test("isDue is true once the review date has passed")
    internal func isDue() {
        var due = newState()
        due.nextReviewDate = Date().addingTimeInterval(-1)
        #expect(SRSEngine.isDue(state: due))

        var notYet = newState()
        notYet.nextReviewDate = Date().addingTimeInterval(SRSEngine.oneDay)
        #expect(!SRSEngine.isDue(state: notYet))
    }

    @Test("dueDescription bins the horizon into human phrases")
    internal func dueDescriptionBins() {
        func desc(daysAhead: Double) -> String {
            var s = newState()
            s.nextReviewDate = Date().addingTimeInterval(daysAhead * SRSEngine.oneDay)
            return SRSEngine.dueDescription(state: s)
        }
        #expect(desc(daysAhead: -3) == "3d overdue")
        #expect(desc(daysAhead: 0) == "Due now")
        #expect(desc(daysAhead: 1) == "Tomorrow")
        #expect(desc(daysAhead: 3) == "In 3 days")
        #expect(desc(daysAhead: 10) == "In 1 week")
        #expect(desc(daysAhead: 21) == "In 3 weeks")
        #expect(desc(daysAhead: 60) == "In 2 months")
        #expect(desc(daysAhead: 400) == ">1 year")
    }
}
