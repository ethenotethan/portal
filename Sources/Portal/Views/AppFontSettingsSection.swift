import SwiftUI

/// Applies the selected typeface to a whole view tree.
///
/// One root modifier rather than a change to the ~1700 `.font(...)` call sites:
/// `.fontDesign(_:)` overrides the `design:` written inside a site's own
/// `.font(.system(...))`, so it reaches text that already sets an explicit size
/// and weight. The flip side is that it also overrides `design: .monospaced`,
/// which is why every monospaced site in the app re-asserts itself with the
/// view-level `.monospaced()` — see `ArchitectureTests`.
extension View {
    internal func portalAppFont() -> some View {
        PortalAppFontBody(content: self)
    }
}

private struct PortalAppFontBody<Content: View>: View {
    internal let content: Content
    @ObservedObject private var themeManager = ThemeManager.shared

    internal var body: some View {
        let theme = themeManager.appFont
        // `system` applies no modifier at all, so an existing user's type is
        // untouched — not even re-declared as `.default`, which would flatten
        // any width or design a view sets for itself.
        if theme.isCustom {
            content
                .fontDesign(Self.design(for: theme))
                .fontWidth(theme == .condensed ? .condensed : nil)
        } else {
            content
        }
    }

    private static func design(for theme: AppFontTheme) -> Font.Design {
        switch theme {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        // Condensed is a width, not a design — the letterforms stay the
        // system's own.
        case .condensed, .system: return .default
        }
    }
}

/// Settings surface for the typeface.
///
/// Its own file, and platform-neutral, for the same reason as
/// `ButtonThemeSettingsSection`: `SettingsView.swift` is already over the
/// `file_length` limit and carries a disable for it.
internal struct AppFontSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    internal let showsHeader: Bool

    internal init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                HStack(spacing: 10) {
                    Image(systemName: "textformat")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text("Font")
                        .font(.title2.weight(.semibold))
                }
            }

            Text("The typeface for text throughout the app. Code blocks, IDs, and logs "
                 + "stay monospaced whichever you pick — those need aligned columns.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(AppFontTheme.allCases) { theme in
                    card(theme)
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ theme: AppFontTheme) -> some View {
        let isSelected = themeManager.appFont == theme
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                themeManager.select(appFont: theme)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Rendered in the typeface on offer, not the selected one — the
                // grid exists to compare the five before committing. `.default`
                // rather than nothing on the others, because a card inside an
                // already-restyled pane would otherwise inherit that pane's font
                // and every preview would look identical.
                Text(theme.sample)
                    .font(.system(size: 22, design: Self.design(for: theme)))
                    .fontWidth(theme == .condensed ? .condensed : .standard)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(theme.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(theme.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? Theme.accent : Theme.border,
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func design(for theme: AppFontTheme) -> Font.Design {
        switch theme {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        case .condensed, .system: return .default
        }
    }
}
