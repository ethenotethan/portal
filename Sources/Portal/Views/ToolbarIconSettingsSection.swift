import SwiftUI

/// Settings surface for the top-right chrome icons: one collective theme to
/// click through, plus a per-button override for anyone who wants Cron amber and
/// the rest left alone.
///
/// Its own file, and platform-neutral, for the same reason as
/// `ButtonThemeSettingsSection` — `SettingsView.swift` is already over the
/// `file_length` limit and carries a disable for it.
internal struct ToolbarIconSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// macOS renders a titled block; iOS embeds the rows in a `Form` section
    /// that supplies its own header.
    internal let showsHeader: Bool

    internal init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text("Toolbar Icons")
                        .font(.title2.weight(.semibold))
                }
            }

            Text("The row in the top right — Settings, Sessions, Cron and the rest. "
                 + "Pick one look for all of them, then adjust any single button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            treatmentGrid
            collectiveTintRow

            Divider()

            perButtonList
        }
    }

    // MARK: - Collective theme

    private var treatmentGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(ToolbarIconTreatment.allCases) { treatment in
                treatmentCard(treatment)
            }
        }
    }

    @ViewBuilder
    private func treatmentCard(_ treatment: ToolbarIconTreatment) -> some View {
        let isSelected = themeManager.toolbarIconTheme == treatment
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                themeManager.select(toolbarIconTheme: treatment)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Real glyphs in this treatment, not the selected one: the grid
                // exists to compare the five before committing.
                HStack(spacing: 6) {
                    ForEach([ToolbarIconSlot.settings, .sessions, .cron], id: \.self) { slot in
                        preview(slot, treatment: treatment, tint: themeManager.toolbarIconTint)
                    }
                }
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(treatment.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(treatment.detail)
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

    private var collectiveTintRow: some View {
        HStack(spacing: 10) {
            Text("Color")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Picker("Color", selection: tintBinding) {
                ForEach(ToolbarIconTint.allCases) { tint in
                    Text(tint.label).tag(tint)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            Spacer(minLength: 0)
        }
    }

    private var tintBinding: Binding<ToolbarIconTint> {
        Binding(
            get: { themeManager.toolbarIconTint },
            set: { themeManager.select(toolbarIconTint: $0) }
        )
    }

    // MARK: - Per-button

    private var perButtonList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Individual buttons")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
                if !themeManager.toolbarIconOverrides.isEmpty {
                    Button("Reset all") { themeManager.resetAllToolbarIcons() }
                        .portalButton(size: .small)
                }
            }

            // Every slot, including the ones the connected harness does not
            // currently expose: a setting that appears and disappears with the
            // connection is worse than one that is occasionally moot.
            ForEach(ToolbarIconSlot.allCases) { slot in
                slotRow(slot)
                if slot != ToolbarIconSlot.allCases.last {
                    Divider().opacity(0.5)
                }
            }
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: ToolbarIconSlot) -> some View {
        let appearance = themeManager.toolbarIconAppearance(for: slot)
        HStack(spacing: 12) {
            preview(slot, treatment: appearance.treatment, tint: appearance.tint)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                // Otherwise an override is invisible: the row shows the button
                // it produced without saying it is no longer following the
                // theme, so clicking through the grid looks broken for it.
                Text(appearance.isOverridden ? "Custom" : "Following the theme")
                    .font(.caption2)
                    .foregroundStyle(appearance.isOverridden ? Theme.accent : Theme.tertiary)
            }

            Spacer(minLength: 0)

            Picker("Look", selection: treatmentBinding(slot)) {
                Text("Theme").tag(ToolbarIconTreatment?.none)
                ForEach(ToolbarIconTreatment.allCases) { treatment in
                    Text(treatment.label).tag(ToolbarIconTreatment?.some(treatment))
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Picker("Color", selection: tintBinding(slot)) {
                Text("Theme").tag(ToolbarIconTint?.none)
                ForEach(ToolbarIconTint.allCases) { tint in
                    Text(tint.label).tag(ToolbarIconTint?.some(tint))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
                themeManager.resetToolbarIcon(slot)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!appearance.isOverridden)
            .help("Return \(slot.label) to the theme")
        }
    }

    private func treatmentBinding(_ slot: ToolbarIconSlot) -> Binding<ToolbarIconTreatment?> {
        Binding(
            get: { themeManager.toolbarIconOverrides.treatment(for: slot) },
            set: { themeManager.setToolbarIcon(treatment: $0, for: slot) }
        )
    }

    private func tintBinding(_ slot: ToolbarIconSlot) -> Binding<ToolbarIconTint?> {
        Binding(
            get: { themeManager.toolbarIconOverrides.tint(for: slot) },
            set: { themeManager.setToolbarIcon(tint: $0, for: slot) }
        )
    }

    // MARK: - Preview glyph

    /// A glyph in the treatment being *offered*, not the selected one. Uses
    /// `ToolbarIconButtonStyle` directly rather than `.toolbarIcon(_:)`, which
    /// would read the live configuration and render every card identically.
    @ViewBuilder
    private func preview(
        _ slot: ToolbarIconSlot,
        treatment: ToolbarIconTreatment,
        tint: ToolbarIconTint
    ) -> some View {
        Button {} label: {
            Image(systemName: slot.systemImage)
        }
        .buttonStyle(ToolbarIconButtonStyle(
            appearance: ToolbarIconAppearance(
                treatment: treatment,
                tint: tint,
                isOverridden: false
            )
        ))
    }
}
