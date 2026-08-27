import CoreGraphics

/// Pure math for chat-layout measurements that feed back into SwiftUI state.
///
/// Both call sites sit inside potential layout feedback loops (measure →
/// publish → state change → re-layout → re-measure). Raw CGFloat measurements
/// are not fixed-point-stable: AppKit/SwiftUI layout re-measures the same
/// content with sub-point jitter, so "did the value change?" is true on every
/// pass and the loop never converges — the recurring main-thread beachball.
/// These helpers make convergence explicit: round the published value and
/// gate adoption behind a tolerance so jitter below a visible delta is
/// absorbed instead of re-entering layout.
enum ChatLayoutMath {
    /// Whether a freshly measured input-field content height should replace
    /// the current one. Sub-point deltas are relayout noise of the same text,
    /// not a content change (a real line change is ~18pt).
    static func shouldAdoptInputHeight(current: CGFloat?, proposed: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        guard let current else { return true }
        return abs(current - proposed) > tolerance
    }

    /// Input-field height clamped to [1 line, maxLines] and rounded to whole
    /// points, so identical content always yields the identical size back to
    /// SwiftUI regardless of sub-point drift in the reported measurement.
    static func clampedInputHeight(
        reported: CGFloat?,
        lineHeight: CGFloat,
        maxLines: Int,
        verticalPadding: CGFloat = 12
    ) -> CGFloat {
        let minH = lineHeight + verticalPadding
        let maxH = lineHeight * CGFloat(maxLines) + verticalPadding
        let h = reported ?? minH
        return min(max(h, minH), maxH).rounded()
    }

    /// Whether a proposed width differs enough from the last recorded one to
    /// be worth storing. Sub-point proposal churn is re-entrant layout noise.
    static func widthMeaningfullyChanged(current: CGFloat?, proposed: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        guard let current else { return true }
        return abs(current - proposed) >= tolerance
    }
}
