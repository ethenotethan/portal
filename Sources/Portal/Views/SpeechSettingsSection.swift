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
            neuralVoiceControls
            neuralPersonaControls
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
        // Weights can arrive (or be deleted) outside the app — the skill
        // summarizer downloads Gemma, and `huggingface-cli` shares the same
        // cache — so re-read on the way in rather than trusting a stale scan.
        .task { localChat.refreshInventory() }
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
                        // "downloaded" or "~4.2 GB to fetch": which of these is a
                        // wait and which is instant is the first thing you want to
                        // know while choosing.
                        Text("\(model.label) \u{00B7} \(localChat.inventory.status(of: model))").tag(model)
                    }
                }
                Text(localChat.model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                localModelProfile
                localModelStatus
            }
        }
    }

    /// What this machine can run, and what of it is already here.
    ///
    /// Three facts, in the order they answer "why that model?": the hardware the
    /// recommendation was read off, what's already on disk (so a pick isn't a
    /// surprise download, and so 17 GB of weights aren't invisible), and the
    /// hardware's own pick with its cost when the user is on something else.
    @ViewBuilder
    private var localModelProfile: some View {
        if !localChat.model.fits(localChat.hardware) {
            Label(
                "This Mac has \(localChat.hardware.memoryGB) GB; \(localChat.model.label) wants "
                    + "at least \(localChat.model.minimumMemoryGB) GB. Expect swapping mid-sentence.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(Theme.warning)
        }

        Text(localChat.hardware.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

        if let onDisk = localChat.inventory.summary {
            Text("On disk: \(onDisk)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if localChat.model != localChat.recommendedModel {
            HStack(spacing: 6) {
                Text("\(localChat.recommendedModel.label) suits this Mac \u{2014} "
                     + "\(localChat.inventory.status(of: localChat.recommendedModel)).")
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

    // MARK: - Neural voice

    /// Opt-in to the on-device neural voice, with the load visible where the
    /// choice is made. Only offered when this build links one; otherwise the
    /// system voice picker below is the whole story.
    @ViewBuilder
    private var neuralVoiceControls: some View {
        if speech.isNeuralVoiceAvailable {
            Toggle("Neural voice", isOn: $speech.usesNeuralVoice)
            Text("Speak with an on-device neural model (PocketTTS) instead of the system voice: "
                 + "natural phrasing, and it starts talking a fraction of a second after a sentence "
                 + "lands. English only. Downloads a few hundred megabytes once on first use; until "
                 + "it has loaded, replies use the system voice below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if speech.usesNeuralVoice {
                neuralVoiceStatus
            }
            Divider()
        }
    }

    /// Persona controls for the neural voice: who speaks, and how warm they
    /// sound. Only shown when the neural voice is switched on and this build
    /// links one — the system voice has its own picker below and ignores
    /// warmth. Offered while the model is still loading so the choice is made
    /// before the first reply, not after hearing the wrong voice.
    @ViewBuilder
    private var neuralPersonaControls: some View {
        if speech.isNeuralVoiceAvailable, speech.usesNeuralVoice, !speech.neuralVoices.isEmpty {
            Picker("Neural voice", selection: $speech.neuralVoice) {
                ForEach(speech.neuralVoices) { option in
                    Text(option.name).tag(option.id)
                }
            }
            Text("Which on-device neural voice speaks. All ship together, so "
                 + "switching is instant once the model has loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Warmth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text(warmthLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.primary)
                }
                Slider(value: $speech.warmth, in: -1...1, step: 0.1) {
                    Text("Warmth")
                } minimumValueLabel: {
                    Image(systemName: "sparkles").font(.caption2)
                } maximumValueLabel: {
                    Image(systemName: "flame").font(.caption2)
                }
            }
            Text("Nudges the neural voice brighter or deeper. The system voice "
                 + "ignores this.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
        }
    }

    /// "Warm +0.4" / "Bright −0.6" / "Neutral" — a word for the direction plus
    /// the value, so the slider reads as a persona choice, not a raw number.
    private var warmthLabel: String {
        let value = speech.warmth
        if abs(value) < 0.05 { return "Neutral" }
        let word = value > 0 ? "Warm" : "Bright"
        return String(format: "%@ %+.1f", word, value)
    }

    @ViewBuilder
    private var neuralVoiceStatus: some View {
        switch speech.neuralState {
        case .preparing:
            Label("Loading the neural voice\u{2026}", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            Label("Neural voice ready", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        case .idle:
            EmptyView()
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

            if speech.speaksWithNeuralVoice {
                Text("The system voice is used only if the neural voice is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let voice = speech.resolvedVoice, voice.quality == .default {
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
