#if canImport(FluidAudio)
import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os

private let voiceEngineLog = Logger(subsystem: "com.ethenotethan.Portal", category: "LocalVoiceEngine")

/// FluidAudio-backed on-device transcriber: Parakeet EOU 120M streaming with
/// 160 ms chunks (lowest-latency tier), English-only. Downloads its CoreML
/// models from HuggingFace on first use, then runs entirely on the Apple Neural
/// Engine — audio never leaves the device. Its built-in end-of-utterance
/// detection is what makes the agent respond right when you stop talking.
///
/// Compiled only when FluidAudio is linked (the app targets, not the SwiftPM
/// test build), so the CoreML/streaming glue stays out of `swift test`. The
/// orchestration in `LocalVoiceService` is what the tests exercise, through the
/// `LocalSpeechTranscribing` seam this type implements.
internal final class FluidAudioTranscriber: LocalSpeechTranscribing {
    private let manager: StreamingEouAsrManager

    internal init() {
        manager = StreamingEouAsrManager(
            configuration: MLModelConfiguration(),
            chunkSize: .ms160
        )
    }

    internal func loadModels() async throws {
        do {
            try await manager.loadModels()
            voiceEngineLog.info("Parakeet EOU streaming models loaded")
        } catch {
            voiceEngineLog.error("Parakeet EOU model load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    internal func onPartial(_ handler: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(handler)
    }

    internal func onEndOfUtterance(_ handler: @escaping @Sendable () -> Void) async {
        // FluidAudio hands the transcript-at-EOU to the callback; the service
        // reads the final text via `finish()`, so the payload is dropped here.
        await manager.setEouCallback { _ in handler() }
    }

    internal func append(_ buffer: AVAudioPCMBuffer) async {
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            // A dropped buffer isn't fatal — the next one keeps the stream alive.
            voiceEngineLog.error("appendAudio/process failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    internal func finish() async throws -> String {
        try await manager.finish()
    }

    internal func reset() async {
        await manager.reset()
    }
}

/// AVAudioEngine microphone capture, forwarding raw buffers to `onBuffer`.
///
/// On iOS the audio session is `.playAndRecord` with `.duckOthers` so the mic
/// coexists with spoken replies (`TTSService` uses `.spokenAudio`) — you can
/// barge in while the agent is talking.
@MainActor
internal final class AVAudioEngineMicrophone: MicrophoneCapturing {
    private let engine = AVAudioEngine()

    /// Snapshotted at `start` and called from the audio thread with a 0...1
    /// loudness per buffer, driving the voice-reactive conversation orb.
    internal var onAudioLevel: (@Sendable (Float) -> Void)?

    /// Fired on the main actor when the audio route changed out from under the
    /// mic and capture was re-armed on the new device, so the UI can reassure
    /// the user instead of sitting in dead silence.
    internal var onRouteInterruption: (@Sendable () -> Void)?

    /// Held so the tap can be reinstalled after a route change: the whole point
    /// of re-arming is that the conversation survives the device switch.
    private var feed: (any LocalSpeechTranscribing)?
    /// Observes the engine's hardware-config changes (a route switch stops the
    /// engine and invalidates the tap format). Removed on `stop`.
    private var configObserver: NSObjectProtocol?

    internal func start(feeding transcriber: any LocalSpeechTranscribing) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)
        #endif
        feed = transcriber
        armCapture(feeding: transcriber)
        engine.prepare()
        try engine.start()
        observeRouteChanges()
    }

    /// Install (or reinstall) the tap on the current input route. Reads the
    /// input format fresh each call so a re-arm after a device switch picks up
    /// the new hardware's sample rate.
    private func armCapture(feeding transcriber: any LocalSpeechTranscribing) {
        let input = engine.inputNode
        // Echo cancellation: with a hands-free conversation the mic stays open
        // while the reply is spoken aloud, so without this the assistant's own
        // voice would be transcribed and loop. Voice-processing I/O runs the
        // system AEC/AGC. Best-effort — if the device/driver can't enable it the
        // mic still works (headphones avoid the echo regardless).
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Non-fatal: fall back to raw capture.
        }
        let format = input.outputFormat(forBus: 0)
        let onLevel = onAudioLevel
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // The engine hands each callback a fresh buffer it will recycle, so
            // transferring it into the transcriber actor is safe; the sending
            // check can't see that, hence `nonisolated(unsafe)`.
            nonisolated(unsafe) let captured = buffer
            Task { await transcriber.append(captured) }
            // Reading the samples here (on the audio thread) is safe; only the
            // hand-off into the actor needed the unsafe transfer above.
            if let onLevel { onLevel(Self.level(of: buffer)) }
        }
    }

    /// Watch for the engine stopping itself on a hardware-config change — a
    /// Bluetooth speaker connecting, headphones (un)plugging, the default device
    /// switching — and rebuild capture on the new route. Before this, such a
    /// switch left the mic dead and the conversation silently one-sided.
    private func observeRouteChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rearmAfterRouteChange() }
        }
    }

    private func rearmAfterRouteChange() {
        // The engine stops itself on a config change; if it's still running this
        // notification isn't a route drop we need to recover from (and re-arming
        // a live engine would loop), so ignore it.
        guard !engine.isRunning, let feed else { return }
        armCapture(feeding: feed)
        engine.prepare()
        do {
            try engine.start()
            onRouteInterruption?()
        } catch {
            voiceEngineLog.error("Mic re-arm after route change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Normalized 0...1 loudness of a capture buffer: RMS mapped from a roughly
    /// -50…-10 dBFS speech window, so quiet rooms sit near 0 and normal talking
    /// swings toward 1. Cheap enough to run on every tap callback.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (decibels + 50) / 40))
    }

    internal func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        feed = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Best-effort deactivation; nothing actionable if the session is
            // already torn down or owned elsewhere.
        }
        #endif
    }

    /// Prompt for (or read) microphone permission on the current platform.
    internal static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #endif
    }
}
#endif
