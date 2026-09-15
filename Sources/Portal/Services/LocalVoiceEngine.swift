#if canImport(FluidAudio)
import AVFoundation
import CoreML
import FluidAudio
import Foundation

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
        try await manager.loadModels()
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // The engine hands each callback a fresh buffer it will recycle, so
            // transferring it into the transcriber actor is safe; the sending
            // check can't see that, hence `nonisolated(unsafe)`.
            nonisolated(unsafe) let captured = buffer
            Task { await transcriber.append(captured) }
        }
        engine.prepare()
        try engine.start()
    }

    internal func stop() {
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
