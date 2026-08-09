import Foundation
import CoreGraphics

/// How a button's corners are cut.
///
/// A radius alone can't express a capsule, whose radius depends on the rendered
/// height — so the shape is a choice, not a number, and the Views layer maps it
/// to an actual shape.
internal enum ButtonCornerStyle: Equatable, Sendable {
    /// Crisp corners. A hairline radius rather than a true 0 — at 1x a perfectly
    /// square corner reads as an unfinished rectangle next to the app's rounded
    /// bubbles and pills.
    case square
    case rounded(CGFloat)
    /// Fully rounded, radius tracking the height.
    case capsule

    /// The radius to use at a given rendered height. `capsule` needs the height;
    /// the others ignore it.
    internal func radius(forHeight height: CGFloat) -> CGFloat {
        switch self {
        case .square: return 2
        case .rounded(let radius): return radius
        case .capsule: return max(height / 2, 0)
        }
    }
}

/// The visual treatment applied to the app's chrome buttons.
///
/// Deliberately orthogonal to `AppTheme`: a button theme carries geometry and
/// emphasis only, and every color it uses comes from the active palette. So the
/// two settings compose — five palettes times six treatments — instead of
/// multiplying into thirty presets that all have to be maintained.
///
/// `system` exists so the shipped look stays reachable. Making a new default the
/// only option would silently restyle every button in the app for users who
/// never asked for it.
///
/// Adding a treatment is a case here plus a branch in `PortalButtonStyle`.
/// Unknown raw values decode to `system` so a preference written by a newer
/// build downgrades rather than failing to load.
internal enum ButtonTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    /// SwiftUI's own `.bordered` / `.borderedProminent`.
    case system
    /// Rounded rectangle, surface fill, hairline border.
    case soft
    /// Capsule.
    case pill
    /// Near-square corners and a thin bright border.
    case sharp
    /// Translucent fill with a top highlight.
    case glass
    /// Dark fill, accent border, accent glow.
    case neon

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .system: return "System"
        case .soft: return "Soft"
        case .pill: return "Pill"
        case .sharp: return "Sharp"
        case .glass: return "Glass"
        case .neon: return "Neon"
        }
    }

    internal var detail: String {
        switch self {
        case .system: return "macOS default buttons."
        case .soft: return "Rounded, filled, understated."
        case .pill: return "Fully rounded capsules."
        case .sharp: return "Square corners and a thin border."
        case .glass: return "Translucent with a soft highlight."
        case .neon: return "Accent border with a glow."
        }
    }

    /// Whether this treatment draws itself at all. `system` hands off to
    /// SwiftUI, so every other property below is meaningless for it — callers
    /// must branch on this rather than reading zeroed-out geometry.
    internal var isCustom: Bool { self != .system }

    internal var cornerStyle: ButtonCornerStyle {
        switch self {
        case .system: return .rounded(6)
        case .soft: return .rounded(6)
        case .pill: return .capsule
        case .sharp: return .square
        case .glass: return .rounded(10)
        case .neon: return .rounded(5)
        }
    }

    internal var borderWidth: CGFloat {
        switch self {
        case .system: return 0
        // Borderless on purpose — it's the fill alone that makes this the
        // quietest treatment, and it's what separates it from `pill`, whose
        // corners are otherwise the only difference.
        case .soft: return 0
        case .pill: return 1
        case .sharp: return 1.5
        case .glass: return 1
        case .neon: return 1.5
        }
    }

    /// Opacity of the palette's surface color behind a non-prominent button.
    internal var fillOpacity: Double {
        switch self {
        case .system: return 0
        case .soft: return 1.0
        case .pill: return 0.9
        // Outline only. A fill plus square corners reads as `soft` with the
        // corners filed off; the empty interior is the treatment.
        case .sharp: return 0
        case .glass: return 0.4
        case .neon: return 0.55
        }
    }

    /// Radius of the accent glow behind the button, 0 for none.
    internal var glowRadius: CGFloat {
        switch self {
        case .neon: return 8
        default: return 0
        }
    }

    /// Whether the border takes the accent color rather than the palette's
    /// border color.
    internal var tintsBorder: Bool {
        self == .neon || self == .sharp
    }

    /// Whether a white gradient sits over the fill, brightest at the top edge.
    ///
    /// A gradient rather than `.ultraThinMaterial`: a material samples what's
    /// behind it, and on the app's flat near-black backgrounds there is nothing
    /// to sample, so it resolves to an opaque light grey — the button came out
    /// lighter than everything around it instead of translucent.
    internal var hasTopHighlight: Bool { self == .glass }

    /// Scale applied while pressed. Every treatment gives some feedback: a
    /// custom style replaces the system's own press highlight, and without a
    /// substitute the button would look inert on click.
    internal var pressedScale: CGFloat {
        switch self {
        case .system: return 1.0
        case .pill: return 0.96
        default: return 0.98
        }
    }

    internal init(storedValue: String?) {
        self = storedValue.flatMap(ButtonTheme.init(rawValue:)) ?? .system
    }
}
