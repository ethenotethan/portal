import SwiftUI

/// The compact transport strip shown above the composer while a response is
/// being read aloud: what sentence the voice is on, pause/resume, and stop.
///
/// Speech used to be fire-and-forget — the only control was the mute toggle,
/// so a forty-second answer had to be sat through or muted for good. This
/// gives it the controls any audio has, in the one place the eye already is
/// while waiting for a reply. Hidden entirely when nothing is playing.
internal struct SpeechNowPlayingBar: View {
    @ObservedObject private var speech = TTSService.shared

    internal init() {}

    internal var body: some View {
        if speech.isActive {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: speech.isSpeaking && !speech.isPaused)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(speech.isPaused ? "Paused" : "Speaking")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    if let sentence = speech.currentSentence, !sentence.isEmpty {
                        Text(sentence)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    speech.togglePause()
                } label: {
                    Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary)
                .help(speech.isPaused ? "Resume speaking" : "Pause speaking")
                .accessibilityIdentifier("speech.togglePause")

                Button {
                    speech.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Stop speaking")
                .accessibilityIdentifier("speech.stop")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(speech.isPaused ? "Speech paused" : "Speaking response")
        }
    }
}
