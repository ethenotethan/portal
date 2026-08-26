import AVFoundation
import Combine
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "TTSService")

/// On-device text-to-speech using Apple's AVSpeechSynthesizer.
/// Speaks assistant responses aloud — no network, no API key, no privacy concerns.
@MainActor
final class TTSService: ObservableObject {
    static let shared = TTSService()

    @Published var isEnabled = false
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let defaultsKey = "portal.tts.enabled"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
        synthesizer.delegate = TTSDelegate.shared

        // Pick a high-quality voice
        let voices = AVSpeechSynthesisVoice.speechVoices()
        // macOS 14+ / iOS 17+ has AVSpeechSynthesisVoice
        if let enhanced = voices.first(where: { $0.quality == .enhanced && $0.language.starts(with: "en") }) {
            preferredVoice = enhanced
        } else if let premium = voices.first(where: { $0.quality == .premium && $0.language.starts(with: "en") }) {
            preferredVoice = premium
        } else if let defaultVoice = voices.first(where: { $0.language.starts(with: "en") }) {
            preferredVoice = defaultVoice
        } else if let anyVoice = voices.first {
            preferredVoice = anyVoice
        }
        log.info("TTS voice: \(self.preferredVoice?.name ?? "none"), quality: \(self.preferredVoice?.quality.rawValue ?? 0)")
    }

    private var preferredVoice: AVSpeechSynthesisVoice?

    func toggle() {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: defaultsKey)
        if !isEnabled {
            stop()
        }
        log.info("TTS \(self.isEnabled ? "enabled" : "disabled")")
    }

    /// Speak a single assistant response.
    func speak(_ text: String) {
        guard isEnabled else { return }
        stop()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
        log.info("TTS speaking \(text.count) chars, voice=\(utterance.voice?.name ?? "default")")
    }

    /// Speak the last assistant message from a list.
    func speakLastAssistantMessage(_ messages: [ChatMessage]) {
        guard let lastBot = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        speak(lastBot.content)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}

// MARK: - Delegate

/// Holds no state of its own: `TTSService` has a `private init` and is reached
/// only through `.shared`, so a back-pointer could never name a different
/// instance than `TTSService.shared` does. Dropping it leaves the delegate
/// immutable, which is what `AVSpeechSynthesizerDelegate`'s Sendable
/// requirement wants — a mutable stored property here is a data race the
/// compiler is right to flag.
private final class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSDelegate()

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            TTSService.shared.isSpeaking = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            TTSService.shared.isSpeaking = false
        }
    }
}
