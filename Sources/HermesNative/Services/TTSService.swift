import AVFoundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "TTSService")

/// On-device text-to-speech using Apple's AVSpeechSynthesizer.
/// Speaks assistant responses aloud — no network, no API key, no privacy concerns.
@MainActor
final class TTSService: ObservableObject {
    static let shared = TTSService()

    @Published var isEnabled = false
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let defaultsKey = "hermes.tts.enabled"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
        synthesizer.delegate = TTSDelegate.shared
        TTSDelegate.shared.service = self

        // Pick a high-quality voice
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let enhanced = voices.first(where: { $0.quality == .enhanced && $0.language.starts(with: "en") }) {
            preferredVoice = enhanced
        } else if let defaultVoice = voices.first(where: { $0.language.starts(with: "en") }) {
            preferredVoice = defaultVoice
        }
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
        utterance.voice = preferredVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1 // slightly faster
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
        log.info("TTS speaking \(text.count) chars")
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

private final class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSDelegate()
    weak var service: TTSService?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.service?.isSpeaking = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.service?.isSpeaking = false
        }
    }
}
