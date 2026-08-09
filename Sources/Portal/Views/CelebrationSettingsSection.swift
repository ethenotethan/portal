import SwiftUI

/// Settings surface for celebration effects.
///
/// Its own file, and platform-neutral, because `SettingsView.swift` is already
/// over the `file_length` limit and carries a `swiftlint:disable` for it — the
/// note at the top of that file asks not to add to it. Both the macOS pane and
/// the iOS form render this same view.
internal struct CelebrationSettingsSection: View {
    @EnvironmentObject internal var settings: SettingsViewModel
    @ObservedObject private var celebrations = CelebrationManager.shared

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
                    Image(systemName: "party.popper")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text("Celebrations")
                        .font(.title2.weight(.semibold))
                }
            }

            Toggle("Celebrate completions", isOn: $settings.celebrationsEnabled)
            Text("Occasional effects when a response finishes, a skill installs, or a cron job succeeds. "
                 + "Off means no animation and no sound.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.celebrationsEnabled {
                Divider()
                stylePicker
                Divider()
                intensityPicker
                Divider()
                extras
                previewButton
            }
        }
    }

    // MARK: - Style

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Effect")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(CelebrationStyle.allCases, id: \.self) { style in
                styleRow(style)
            }
        }
    }

    @ViewBuilder
    private func styleRow(_ style: CelebrationStyle) -> some View {
        let isSelected = settings.celebrationStyle == style
        Button {
            settings.celebrationStyle = style
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(style.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Intensity

    private var intensityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Frequency", selection: $settings.celebrationIntensity) {
                ForEach(CelebrationIntensity.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)

            // Says what the control actually changes. It scales the odds of a
            // celebration firing, not the size of one — "subtle" would otherwise
            // read as "smaller confetti".
            Text("How often celebrations happen, and at most one every "
                 + "\(Int(settings.celebrationIntensity.throttleInterval))s.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Extras

    private var extras: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Confetti particles", isOn: $settings.celebrationParticlesEnabled)
                // Only the confetti effect draws them, so for the others this
                // control would silently do nothing.
                .disabled(!settings.celebrationStyle.usesParticles)
            if !settings.celebrationStyle.usesParticles {
                Text("The \(settings.celebrationStyle.label) effect doesn’t use particles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Sound", isOn: $settings.celebrationSoundEnabled)
        }
    }

    private var previewButton: some View {
        Button {
            celebrations.preview()
        } label: {
            Label("Preview", systemImage: "play.circle")
        }
        .buttonStyle(.bordered)
    }
}
