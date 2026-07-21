import CoreGraphics
import Testing
@testable import HermesNative

@Suite("Chat Layout Math")
struct ChatLayoutMathTests {

    // MARK: - avatarY (turn-probe preference value)

    @Test("Avatar Y is whole-point quantized so sub-pixel jitter converges")
    func avatarYQuantizesJitter() {
        // The beachball loop: maxY jitters by fractions of a point every
        // layout pass, minting a distinct preference value each time. All
        // jittered inputs within half a point must map to the same output.
        let base = ChatLayoutMath.avatarY(fromProbeMaxY: 400.0)
        #expect(ChatLayoutMath.avatarY(fromProbeMaxY: 400.2) == base)
        #expect(ChatLayoutMath.avatarY(fromProbeMaxY: 399.8) == base)
        #expect(base == 340) // 400 - 60, rounded
        #expect(base.truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test("Avatar Y clamps at zero and applies the bottom inset")
    func avatarYClampsAndInsets() {
        #expect(ChatLayoutMath.avatarY(fromProbeMaxY: 30) == 0)
        #expect(ChatLayoutMath.avatarY(fromProbeMaxY: 0) == 0)
        #expect(ChatLayoutMath.avatarY(fromProbeMaxY: 100, bottomInset: 60) == 40)
    }

    @Test("Avatar move hysteresis absorbs sub-threshold ping-pong")
    func avatarMoveHysteresis() {
        // Rounded values can still ping-pong across a rounding boundary
        // (340 <-> 341) under jitter; the dead band must absorb that.
        #expect(!ChatLayoutMath.shouldMoveAvatar(from: 340, to: 341))
        #expect(!ChatLayoutMath.shouldMoveAvatar(from: 340, to: 343.9))
        #expect(ChatLayoutMath.shouldMoveAvatar(from: 340, to: 344))
        #expect(ChatLayoutMath.shouldMoveAvatar(from: 340, to: 300))
        // Symmetric in both directions.
        #expect(!ChatLayoutMath.shouldMoveAvatar(from: 341, to: 340))
        #expect(ChatLayoutMath.shouldMoveAvatar(from: 344, to: 340))
    }

    @Test("Avatar adopt-then-remeasure reaches a fixed point")
    func avatarFeedbackConverges() {
        // Simulate the loop: adopt Y, layout re-measures with jitter, ask
        // again. After the first adoption no further move may be requested.
        var current: CGFloat = 0
        let measured = ChatLayoutMath.avatarY(fromProbeMaxY: 512.3)
        #expect(ChatLayoutMath.shouldMoveAvatar(from: current, to: measured))
        current = measured
        for jitter in [512.0, 512.7, 511.9, 512.4] {
            let next = ChatLayoutMath.avatarY(fromProbeMaxY: CGFloat(jitter))
            #expect(!ChatLayoutMath.shouldMoveAvatar(from: current, to: next))
        }
    }

    // MARK: - Input-field height

    @Test("Sub-point height deltas are absorbed, real line changes adopted")
    func inputHeightTolerance() {
        // First measurement is always adopted.
        #expect(ChatLayoutMath.shouldAdoptInputHeight(current: nil, proposed: 30))
        // Relayout noise of the same text: absorbed.
        #expect(!ChatLayoutMath.shouldAdoptInputHeight(current: 30, proposed: 30.4))
        #expect(!ChatLayoutMath.shouldAdoptInputHeight(current: 30.4, proposed: 30))
        // A real line change (~18pt): adopted.
        #expect(ChatLayoutMath.shouldAdoptInputHeight(current: 30, proposed: 48))
        #expect(ChatLayoutMath.shouldAdoptInputHeight(current: 48, proposed: 30))
    }

    @Test("Clamped input height is stable for identical inputs")
    func clampedInputHeightStability() {
        let lineHeight: CGFloat = 18.1
        let a = ChatLayoutMath.clampedInputHeight(reported: 54.3, lineHeight: lineHeight, maxLines: 8)
        let b = ChatLayoutMath.clampedInputHeight(reported: 54.3, lineHeight: lineHeight, maxLines: 8)
        #expect(a == b)
        #expect(a.truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test("Clamped input height respects the one-line floor and maxLines cap")
    func clampedInputHeightBounds() {
        let lineHeight: CGFloat = 18
        // No measurement yet → one line + padding.
        #expect(ChatLayoutMath.clampedInputHeight(reported: nil, lineHeight: lineHeight, maxLines: 8) == 30)
        // Below the floor → clamped up.
        #expect(ChatLayoutMath.clampedInputHeight(reported: 5, lineHeight: lineHeight, maxLines: 8) == 30)
        // Above the cap → clamped to maxLines.
        #expect(ChatLayoutMath.clampedInputHeight(reported: 999, lineHeight: lineHeight, maxLines: 8) == 156)
    }

    @Test("Width fallback only updates on a meaningful change")
    func widthChangeGate() {
        #expect(ChatLayoutMath.widthMeaningfullyChanged(current: nil, proposed: 300))
        #expect(!ChatLayoutMath.widthMeaningfullyChanged(current: 300, proposed: 300.3))
        #expect(!ChatLayoutMath.widthMeaningfullyChanged(current: 300.3, proposed: 300))
        #expect(ChatLayoutMath.widthMeaningfullyChanged(current: 300, proposed: 301))
        #expect(ChatLayoutMath.widthMeaningfullyChanged(current: 300, proposed: 250))
    }
}
