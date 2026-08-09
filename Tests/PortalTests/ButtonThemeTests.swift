import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import Portal

/// The button treatment is a second appearance axis alongside `AppTheme`, and it
/// reaches ~70 call sites through one modifier. These tests pin the parts that
/// would be invisible until they were wrong everywhere at once: a treatment that
/// draws no border and no fill (an invisible button), a stored preference that
/// refuses to load, and `system` leaking geometry it does not own.
@Suite("Button themes")
internal struct ButtonThemeTests {

    // MARK: - Every treatment is visible

    @Test("every custom treatment draws something")
    internal func customTreatmentsAreVisible() {
        for theme in ButtonTheme.allCases where theme.isCustom {
            // A treatment with no border and no fill renders an invisible
            // button — the label floats with nothing behind it and there is no
            // hit target to see.
            let hasEdge = theme.borderWidth > 0
            let hasFill = theme.fillOpacity > 0
            #expect(hasEdge || hasFill, "\(theme.rawValue) draws neither border nor fill")
        }
    }

    @Test("every treatment gives press feedback")
    internal func everyTreatmentRespondsToPress() {
        for theme in ButtonTheme.allCases where theme.isCustom {
            // A custom style replaces the system's own press highlight, so
            // without a substitute the button looks inert when clicked.
            #expect(theme.pressedScale < 1.0)
            // …but not so far that it reads as a glitch.
            #expect(theme.pressedScale > 0.9)
        }
    }

    @Test("fill opacities stay in range")
    internal func fillOpacitiesAreValid() {
        for theme in ButtonTheme.allCases {
            #expect(theme.fillOpacity >= 0)
            #expect(theme.fillOpacity <= 1)
        }
    }

    // MARK: - system is a hand-off, not a treatment

    @Test("system is the only non-custom treatment")
    internal func systemIsTheHandOff() {
        // `.portalButton()` branches on this to reach `.bordered` /
        // `.borderedProminent`; a custom treatment that reported `false` would
        // silently never be drawn.
        #expect(!ButtonTheme.system.isCustom)
        for theme in ButtonTheme.allCases where theme != .system {
            #expect(theme.isCustom)
        }
    }

    @Test("system draws no border and no glow of its own")
    internal func systemDrawsNothingItself() {
        // SwiftUI owns the rendering, so any geometry here would be dead values
        // that a future refactor could start honoring by accident.
        #expect(ButtonTheme.system.borderWidth == 0)
        #expect(ButtonTheme.system.fillOpacity == 0)
        #expect(ButtonTheme.system.glowRadius == 0)
        #expect(ButtonTheme.system.pressedScale == 1.0)
    }

    @Test("system is the default, so the shipped look is what an existing user keeps")
    internal func systemIsTheDefault() {
        // Every button in the app changes at once here. Defaulting to anything
        // else restyles the whole UI for users who never asked.
        #expect(ButtonTheme(storedValue: nil) == .system)
    }

    // MARK: - Corner geometry

    @Test("a capsule's radius tracks its height")
    internal func capsuleRadiusFollowsHeight() {
        let capsule = ButtonCornerStyle.capsule
        #expect(capsule.radius(forHeight: 26) == 13)
        #expect(capsule.radius(forHeight: 40) == 20)
        // The reason the shape is a case rather than a number: a fixed radius
        // cannot express this.
        #expect(capsule.radius(forHeight: 26) != capsule.radius(forHeight: 40))
    }

    @Test("a fixed radius ignores the height")
    internal func fixedRadiusIgnoresHeight() {
        let rounded = ButtonCornerStyle.rounded(8)
        #expect(rounded.radius(forHeight: 20) == 8)
        #expect(rounded.radius(forHeight: 200) == 8)
    }

    @Test("square corners are a hairline, not a true zero")
    internal func squareIsAHairline() {
        // At 1x a perfectly square corner reads as an unfinished rectangle next
        // to the app's rounded bubbles and pills.
        let radius = ButtonCornerStyle.square.radius(forHeight: 26)
        #expect(radius > 0)
        #expect(radius < 4)
    }

    @Test("a zero height cannot produce a negative radius")
    internal func degenerateHeightIsClamped() {
        // Reachable during the first layout pass, before a frame is resolved. A
        // negative radius is a CoreGraphics precondition failure, not a visual
        // glitch.
        for style in [ButtonCornerStyle.capsule, .square, .rounded(8)] {
            #expect(style.radius(forHeight: 0) >= 0)
            #expect(style.radius(forHeight: -50) >= 0)
        }
    }

    @Test("only pill is a capsule")
    internal func onlyPillIsACapsule() {
        #expect(ButtonTheme.pill.cornerStyle == .capsule)
        for theme in ButtonTheme.allCases where theme != .pill {
            #expect(theme.cornerStyle != .capsule)
        }
    }

    // MARK: - Distinctness

    @Test("the treatments are visually distinct from one another")
    internal func treatmentsAreDistinct() {
        // Two identical treatments are two rows in the picker that do the same
        // thing, which reads as a broken setting.
        let signatures = ButtonTheme.allCases.map { theme in
            [
                "\(theme.cornerStyle)",
                "\(theme.borderWidth)",
                "\(theme.fillOpacity)",
                "\(theme.glowRadius)",
                "\(theme.tintsBorder)",
                "\(theme.hasTopHighlight)",
            ].joined(separator: "|")
        }
        #expect(Set(signatures).count == signatures.count)
    }

    @Test("every treatment has a distinct label and a detail")
    internal func labelsAreDistinct() {
        let labels = ButtonTheme.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        for theme in ButtonTheme.allCases {
            #expect(!theme.label.isEmpty)
            #expect(!theme.detail.isEmpty)
        }
    }

    // MARK: - Stored value decoding

    @Test("an unknown stored treatment downgrades to system")
    internal func unknownValueDowngrades() {
        // A preference written by a newer build, or a hand-edited defaults
        // plist. Refusing to load would leave every button unstyled.
        #expect(ButtonTheme(storedValue: "brutalist") == .system)
        #expect(ButtonTheme(storedValue: "") == .system)
        #expect(ButtonTheme(storedValue: "neon") == .neon)
    }

    @Test("every treatment round-trips through its raw value")
    internal func rawValuesRoundTrip() {
        for theme in ButtonTheme.allCases {
            #expect(ButtonTheme(storedValue: theme.rawValue) == theme)
            // `id` backs `ForEach` in the picker; colliding ids drop rows.
            #expect(theme.id == theme.rawValue)
        }
        #expect(Set(ButtonTheme.allCases.map(\.id)).count == ButtonTheme.allCases.count)
    }

    // MARK: - Tint

    @Test("an untinted button uses the palette accent")
    internal func untintedFallsBackToPalette() {
        let style = PortalButtonStyle(theme: .neon)
        #expect(style.tint == nil)
    }

    @Test("a tint is carried, so a destructive button can differ from its neighbor")
    internal func tintIsCarried() {
        // `.tint(_:)` and `role: .destructive` never reach a custom
        // `ButtonStyle`, so this parameter is the only channel. Losing it makes
        // Deny look exactly like Approve, which is one misclick from being
        // taken.
        let style = PortalButtonStyle(theme: .soft, tint: .red)
        #expect(style.tint == .red)
    }

    // MARK: - Control sizes

    @Test("small is smaller than regular in every dimension")
    internal func smallIsSmaller() {
        // The style owns its metrics because SwiftUI's `.controlSize(_:)` has no
        // effect on a custom `ButtonStyle` — so these are the only numbers that
        // distinguish the two, and an inverted one is a visible layout bug.
        #expect(PortalControlSize.small.fontSize < PortalControlSize.regular.fontSize)
        #expect(PortalControlSize.small.minHeight < PortalControlSize.regular.minHeight)
        #expect(PortalControlSize.small.horizontalPadding
                < PortalControlSize.regular.horizontalPadding)
        #expect(PortalControlSize.small.verticalPadding
                < PortalControlSize.regular.verticalPadding)
    }

    @Test("a label fits inside the minimum height at both sizes")
    internal func labelFitsMinimumHeight() {
        for size in [PortalControlSize.small, .regular] {
            // Padding plus text must not exceed the frame, or the label clips.
            #expect(size.fontSize + size.verticalPadding * 2 <= size.minHeight)
        }
    }
}
