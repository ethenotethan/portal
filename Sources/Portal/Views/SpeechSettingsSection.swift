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
    @ObservedObject private var localVoice = LocalVoiceService.shared
    @ObservedObject private var localChat = LocalChatService.shared

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

            if localVoice.isAvailable {
                Divider()
                Toggle("On-device voice input", isOn: $localVoice.isEnabled)
                Text("Transcribe the mic button locally with a Parakeet speech model instead of "
                     + "sending audio to the gateway. English, low-latency, and fully on-device — "
                     + "the model downloads once on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if localVoice.isEnabled {
                    Toggle("Conversation mode", isOn: $localVoice.conversationMode)
                    Text("Have a spoken back-and-forth: tap the mic once and the app keeps "
                         + "listening after each reply, so you can ask follow-ups without "
                         + "tapping again. Tap the mic to end. Needs \u{201C}Speak responses\u{201D} on "
                         + "to hear replies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Conversation look", selection: $localVoice.conversationVisual) {
                        ForEach(ConversationVisual.allCases) { visual in
                            Text(visual.label).tag(visual)
                        }
                    }
                    Text("How the conversation looks while it's live: a warm organic orb or a "
                         + "glowing gradient sphere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            localDiscussionControls

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

    // MARK: - Local discussion

    /// Opt-in and model choice for talking a reply over with an on-device model.
    ///
    /// Lives next to the speech controls because it *is* a speech feature from
    /// where the user sits: the alternative to having a reply read at you is
    /// talking about it. The model picker shows download sizes because picking
    /// one is committing to a download.
    @ViewBuilder
    private var localDiscussionControls: some View {
        if localChat.isAvailable {
            Divider()
            Toggle("Discuss replies on-device", isOn: $localChat.isEnabled)
            Text("Adds a \u{201C}discuss\u{201D} button under each reply. Instead of having the whole "
                 + "answer read to you, talk it over with a local model — free, private, and kept "
                 + "out of the session — then hand what you decided back to the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if localChat.isEnabled {
                Picker("Local model", selection: $localChat.model) {
                    ForEach(LocalChatModel.allCases) { model in
                        Text("\(model.label) \u{00B7} \(model.downloadSize)").tag(model)
                    }
                }
                Text(localChat.model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                localModelFit
                localModelStatus
            }
        }
    }

    /// How the pick lands on *this* machine. Which model is right is mostly a
    /// memory question, and the user can't be expected to know that a 30B-A3B
    /// wants 32 GB — so say it, and offer the model that suits the hardware.
    @ViewBuilder
    private var localModelFit: some View {
        if !localChat.model.fits(localChat.hardware) {
            Label(
                "This Mac has \(localChat.hardware.memoryGB) GB; \(localChat.model.label) wants "
                    + "at least \(localChat.model.minimumMemoryGB) GB. Expect swapping mid-sentence.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(Theme.warning)
        }
        if localChat.model != localChat.recommendedModel {
            HStack(spacing: 6) {
                Text("\(localChat.hardware.summary) suits \(localChat.recommendedModel.label).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Use it") { localChat.model = localChat.recommendedModel }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// The load is kicked off by opting in or switching models, so this is where
    /// a multi-gigabyte download is visible rather than mid-conversation.
    @ViewBuilder
    private var localModelStatus: some View {
        if localChat.isPreparing {
            Label("Loading \(localChat.model.label)\u{2026}", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = localChat.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        } else if localChat.isReady {
            Label("\(localChat.model.label) ready", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("Best for your region (\(speech.resolvedVoice.map(Self.label(for:)) ?? "system default"))")
                    .tag(String?.none)
                ForEach(voices, id: \.identifier) { voice in
                    Text(Self.label(for: voice)).tag(Optional(voice.identifier))
                }
            }
            .labelsHidden()

            Toggle("Show voices for all languages", isOn: $showsAllLanguages)
                .font(.caption)

            if let voice = speech.resolvedVoice, voice.quality == .default {
                Label(
                    "\(voice.name) is a compact voice and will sound synthetic. Download an Enhanced or Premium voice "
                    + "in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, then pick it here.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Theme.warning)
            } else {
                Text("Higher-quality voices are downloaded in System Settings → Accessibility → Spoken Content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
