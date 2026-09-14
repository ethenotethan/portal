import AVFoundation
import SwiftUI

/// Settings surface for spoken responses.
///
/// Its own file, like `CelebrationSettingsSection`, because `SettingsView.swift`
/// is over the `file_length` limit. Both the macOS pane and the iOS form render
/// this same view. Every control writes straight to `TTSService`, which
/// persists it — there's no second copy of the state to drift.
internal struct SpeechSettingsSection: View {
    @ObservedObject private var speech = TTSService.shared

    /// macOS renders a titled pane; iOS embeds the rows in a `Form` section that
    /// supplies its own header.
    internal let showsHeader: Bool
    /// Voices for every installed language, not just the current locale's.
    @State private var showsAllLanguages = false

    internal init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text("Speech")
                        .font(.title2.weight(.semibold))
                }
            }

            Toggle("Speak responses", isOn: $speech.isEnabled)
            Text("Read each assistant reply aloud with an on-device voice. Nothing leaves the device. "
                 + "Any message can also be read on demand from the speaker button under it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Toggle("Start while the reply is still streaming", isOn: $speech.speaksWhileStreaming)
            Text("Speaks each sentence as soon as it's complete instead of waiting for the whole answer.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Announce code blocks", isOn: $speech.announcesCodeBlocks)
            Text("Say \"Code block omitted\" where a snippet was, rather than skipping it silently. "
                 + "Code, links and markdown syntax are never read out character by character.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            voicePicker
            Divider()
            rateSlider

            Button {
                speech.previewVoice()
            } label: {
                Label("Preview voice", systemImage: "play.circle")
            }
            .portalButton(size: .small)

            #if os(iOS)
            Text("Speech keeps playing when the screen locks; pause it from the lock screen or your headphones.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #else
            Text("Pause and resume with the media keys or the Now Playing widget.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    // MARK: - Voice

    private var languageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private var voices: [AVSpeechSynthesisVoice] {
        let all = TTSService.availableVoices()
        if showsAllLanguages { return all }
        let local = all.filter { $0.language.hasPrefix(languageCode) }
        return local.isEmpty ? all : local
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker("Voice", selection: $speech.voiceIdentifier) {
                Text("Best available (\(speech.resolvedVoice?.name ?? "system default"))")
                    .tag(String?.none)
                ForEach(voices, id: \.identifier) { voice in
                    Text(Self.label(for: voice)).tag(Optional(voice.identifier))
                }
            }
            .labelsHidden()

            Toggle("Show voices for all languages", isOn: $showsAllLanguages)
                .font(.caption)

            Text("Higher-quality voices are downloaded in System Settings → Accessibility → Spoken Content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Samantha · en-US · Enhanced" — the name alone is ambiguous once a voice
    /// exists in several qualities.
    internal static func label(for voice: AVSpeechSynthesisVoice) -> String {
        var parts = [voice.name, voice.language]
        switch voice.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Enhanced")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rate

    private var rateSlider: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(String(format: "%.2f×", speech.rateMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.primary)
            }
            Slider(value: $speech.rateMultiplier, in: 0.5...2.0, step: 0.05) {
                Text("Speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise").font(.caption2)
            } maximumValueLabel: {
                Image(systemName: "hare").font(.caption2)
            }
        }
    }
}
