import SwiftUI

/// Renders a button in the user's chosen `ButtonTheme`.
///
/// Every color comes from the active palette, so this composes with the theme
/// picker rather than competing with it.
internal struct PortalButtonStyle: ButtonStyle {
    /// Whether this is the call-to-action in its context — the replacement for
    /// `.borderedProminent`.
    internal let isProminent: Bool
    internal let theme: ButtonTheme
    internal let controlSize: PortalControlSize
    /// Overrides the palette accent for this one button.
    ///
    /// A custom `ButtonStyle` does not receive `.tint(_:)` or a `role:` — those
    /// only reach SwiftUI's own bordered styles. Without an explicit channel,
    /// Approve/Deny pairs would come out identically accent-colored and a
    /// destructive confirmation would stop reading as dangerous.
    internal let tint: Color?

    internal init(
        isProminent: Bool = false,
        theme: ButtonTheme,
        controlSize: PortalControlSize = .regular,
        tint: Color? = nil
    ) {
        self.isProminent = isProminent
        self.theme = theme
        self.controlSize = controlSize
        self.tint = tint
    }

    /// The color this button emphasizes with.
    private var accent: Color { tint ?? Theme.accent }

    internal func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: controlSize.fontSize, weight: isProminent ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, controlSize.horizontalPadding)
            .padding(.vertical, controlSize.verticalPadding)
            .frame(minHeight: controlSize.minHeight)
            .background { background }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? theme.pressedScale : 1)
            // The custom style replaces the system's press highlight, so it has
            // to supply its own or the button looks inert when clicked.
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    // MARK: - Pieces

    /// Resolved once here rather than per-layer: `capsule` needs the rendered
    /// height, and `minHeight` is the only height this style actually knows.
    private var shape: AnyShape {
        let radius = theme.cornerStyle.radius(forHeight: controlSize.minHeight)
        if case .capsule = theme.cornerStyle {
            return AnyShape(Capsule())
        }
        return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var foreground: Color {
        // A prominent button fills with the accent, so its label has to sit on
        // that fill — the palette's primary text color would vanish into it on
        // the lighter accents (forest's lime, ocean's mint).
        if isProminent { return Theme.background }
        // An explicit tint colors the label, matching what `.bordered` does with
        // `.tint(_:)` and with `role: .destructive`. That coloring is the whole
        // signal on a Deny or a Remove: a destructive action that looks exactly
        // like its neighbor is one misclick from being taken.
        return tint ?? Theme.primary
    }

    private var borderColor: Color {
        if isProminent { return accent }
        return theme.tintsBorder ? accent.opacity(0.7) : Theme.border
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            // Outside the clip below: a glow is light spilling past the button's
            // edge, and clipping it to the shape would erase the whole effect.
            if theme.glowRadius > 0 {
                shape
                    .fill(accent.opacity(isProminent ? 0.5 : 0.28))
                    .blur(radius: theme.glowRadius)
            }

            fillAndBorder
        }
    }

    @ViewBuilder
    private var fillAndBorder: some View {
        ZStack {
            if isProminent {
                shape.fill(accent)
            } else {
                shape.fill(Theme.surface.opacity(theme.fillOpacity))
            }

            if theme.hasTopHighlight {
                // The thing that reads as "glass": light catching the top edge
                // and falling off. Applied over the accent too, so a prominent
                // glass button is lit the same way as a plain one.
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // Stroked at double width and clipped, rather than `strokeBorder`:
            // that is an `InsettableShape` method and `AnyShape` erases the
            // insettability. Clipping discards the outer half, which is what
            // `strokeBorder` would have inset away.
            shape.stroke(borderColor, lineWidth: theme.borderWidth * 2)
        }
        .clipShape(shape)
    }
}

/// The subset of `ControlSize` the app actually uses at button call sites.
///
/// Its own type because SwiftUI's `.controlSize(_:)` has no effect on a custom
/// `ButtonStyle` — the style owns its metrics, so the size has to reach it as a
/// parameter instead of through the environment.
internal enum PortalControlSize: Sendable {
    case small
    case regular

    internal var fontSize: CGFloat {
        switch self {
        case .small: return 11
        case .regular: return 13
        }
    }

    internal var horizontalPadding: CGFloat {
        switch self {
        case .small: return 8
        case .regular: return 12
        }
    }

    internal var verticalPadding: CGFloat {
        switch self {
        case .small: return 3
        case .regular: return 5
        }
    }

    internal var minHeight: CGFloat {
        switch self {
        case .small: return 20
        case .regular: return 26
        }
    }
}

// MARK: - Call-site modifier

extension View {
    /// Apply the user's button theme, falling back to SwiftUI's own bordered
    /// styles when they've chosen `system`.
    ///
    /// A modifier rather than a bare `ButtonStyle` because `system` has to reach
    /// `.bordered` / `.borderedProminent`, and a `ButtonStyle` cannot decline to
    /// style its button. Reading `ThemeManager.shared` here — rather than taking
    /// the theme as an argument — keeps the ~70 call sites to one modifier each
    /// and means none of them need a `@ObservedObject`.
    @ViewBuilder
    internal func portalButton(
        prominent: Bool = false,
        size: PortalControlSize = .regular,
        tint: Color? = nil
    ) -> some View {
        PortalButtonModifierBody(content: self, prominent: prominent, size: size, tint: tint)
    }
}

/// Observes `ThemeManager` so a theme change re-renders the button.
///
/// A view rather than a `ViewModifier` because the branch on `isCustom` changes
/// which `ButtonStyle` is applied, and that has to happen inside a body that
/// SwiftUI re-invokes when the observed object changes.
private struct PortalButtonModifierBody<Content: View>: View {
    internal let content: Content
    internal let prominent: Bool
    internal let size: PortalControlSize
    internal let tint: Color?
    @ObservedObject private var themeManager = ThemeManager.shared

    internal var body: some View {
        let theme = themeManager.buttonTheme
        if theme.isCustom {
            content.buttonStyle(
                PortalButtonStyle(
                    isProminent: prominent, theme: theme, controlSize: size, tint: tint
                )
            )
        } else {
            // `system` hands off to SwiftUI, which reads `.tint(_:)` from the
            // environment — so the tint is applied as a modifier there rather
            // than passed as a parameter.
            systemStyled.tint(tint)
        }
    }

    @ViewBuilder
    private var systemStyled: some View {
        if prominent {
            content
                .buttonStyle(.borderedProminent)
                .controlSize(size == .small ? .small : .regular)
        } else {
            content
                .buttonStyle(.bordered)
                .controlSize(size == .small ? .small : .regular)
        }
    }
}
