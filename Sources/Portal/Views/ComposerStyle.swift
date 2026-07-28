import SwiftUI

/// Selectable visual treatments for the chat composer ("chat bar") — the docked
/// input row where the user types and sends. Separate from `ChatSkin` (which
/// styles message bubbles and the streaming panel): the composer's frame is its
/// own decision, so it can be toggled independently in the canvas edit toolbar.
///
/// A style only decides the composer's *container* look (fill, border, corner
/// radius, shadow); the field, attach button, and send/stop button inside it are
/// shared across styles.
enum ComposerStyle: String, CaseIterable, Identifiable, Sendable {
    /// The default: a rounded surface card with a hairline border and a soft
    /// drop shadow — the floating-panel look.
    case card = "card"
    /// A single-line pill: fully rounded, thin border, no shadow — quieter and
    /// more compact, closer to a search bar.
    case pill = "pill"
    /// Chrome-free: no fill, no border, no shadow — just a rule above the row so
    /// the composer melts into the transcript below it.
    case minimal = "minimal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .card: return "Card"
        case .pill: return "Pill"
        case .minimal: return "Minimal"
        }
    }

    var icon: String {
        switch self {
        case .card: return "rectangle.roundedtop"
        case .pill: return "capsule"
        case .minimal: return "minus"
        }
    }

    /// The next style in the cycle — for a single toggle button that rotates
    /// through the options rather than opening a menu.
    var next: ComposerStyle {
        let all = ComposerStyle.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

    // MARK: - Container appearance

    var cornerRadius: CGFloat {
        switch self {
        case .card: return 12
        case .pill: return 22
        case .minimal: return 0
        }
    }

    /// Fill behind the composer row. nil = no fill (the row shows the view
    /// behind it).
    var fill: Color? {
        switch self {
        case .card, .pill: return Theme.surface
        case .minimal: return nil
        }
    }

    var borderColor: Color? {
        switch self {
        case .card: return Theme.border.opacity(0.9)
        case .pill: return Theme.border.opacity(0.6)
        case .minimal: return nil
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .card, .pill: return 1
        case .minimal: return 0
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .card: return 18
        case .pill, .minimal: return 0
        }
    }

    /// A top rule, used by `.minimal` to separate the composer from the
    /// transcript when it has no container of its own.
    var showsTopDivider: Bool {
        self == .minimal
    }
}

// MARK: - Container modifier

extension View {
    /// Apply a `ComposerStyle`'s container decoration (fill, border, shadow,
    /// corner radius) to the composer row. A no-op for `.minimal` (which draws a
    /// top divider inside the row instead).
    func composerContainer(_ style: ComposerStyle) -> some View {
        modifier(ComposerContainerModifier(style: style))
    }
}

private struct ComposerContainerModifier: ViewModifier {
    let style: ComposerStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        return content
            .background {
                if let fill = style.fill {
                    shape.fill(fill)
                }
            }
            .overlay {
                if let border = style.borderColor {
                    shape.stroke(border, lineWidth: style.borderWidth)
                }
            }
            .clipShape(shape)
            .shadow(
                color: .black.opacity(style.shadowRadius > 0 ? 0.28 : 0),
                radius: style.shadowRadius,
                x: 0,
                y: style.shadowRadius > 0 ? 8 : 0
            )
    }
}
