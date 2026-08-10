import SwiftUI

/// Settings surface for the button treatment.
///
/// Its own file, and platform-neutral, because `SettingsView.swift` is already
/// over the `file_length` limit and carries a `swiftlint:disable` for it — the
/// note at the top of that file asks not to add to it. Both the macOS pane and
/// the iOS form render this same view.
internal struct ButtonThemeSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// macOS renders a titled pane; iOS embeds the rows in a `Form` section that
    /// supplies its own header.
    internal let showsHeader: Bool

    internal init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                HStack(spacing: 10) {
                    Image(systemName: "capsule")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text("Buttons")
                        .font(.title2.weight(.semibold))
                }
            }

            Text("Shape and emphasis for buttons throughout the app. Colors come from the "
                 + "selected theme, so the two settings combine.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                ForEach(ButtonTheme.allCases) { theme in
                    card(theme)
                }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(_ theme: ButtonTheme) -> some View {
        let isSelected = themeManager.buttonTheme == theme
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                themeManager.select(buttonTheme: theme)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Live samples in this treatment, regardless of what's currently
                // selected — the point of the grid is to compare them before
                // committing, not to read six descriptions.
                HStack(spacing: 8) {
                    sample(theme, prominent: true, title: "Save")
                    sample(theme, prominent: false, title: "Cancel")
                }
                .allowsHitTesting(false)

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

    /// A sample button in `theme`, not in the selected one. Uses
    /// `PortalButtonStyle` directly rather than `.portalButton()`, which would
    /// read the current selection and render six identical previews.
    @ViewBuilder
    private func sample(_ theme: ButtonTheme, prominent: Bool, title: String) -> some View {
        let button = Button(title) {}
        if theme.isCustom {
            button.buttonStyle(
                PortalButtonStyle(isProminent: prominent, theme: theme, controlSize: .small)
            )
        } else if prominent {
            button.buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }
}
