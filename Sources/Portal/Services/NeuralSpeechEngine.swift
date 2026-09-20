#if canImport(FluidAudio)
import AVFoundation
import FluidAudio
import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "NeuralSpeechEngine")

/// FluidAudio's PocketTTS as a Portal voice: Kyutai's flow-matching model,
/// streamed 80 ms at a time from CoreML into an `AVAudioPlayerNode`.
///
/// Chosen over the other backends in the package because it is the one built
/// for a conversation: the first frame plays tens of milliseconds after the
/// text arrives, and the rest streams behind it while the model is still
/// generating. The system voice, by contrast, shapes intonation once per
/// utterance and sounds like a paragraph being read — which is what made
/// hands-free replies feel uncanny.
///
/// Each utterance is one `synthesizeStreaming` call, so its boundaries are
/// exact: `started` fires as its first buffer renders, `finished` as its last
/// buffer finishes playing. Utterances queue in order; the model runs ahead
/// of playback (several times real time), so consecutive sentences are
/// gapless. Speaking rate is applied with a time-pitch unit rather than by
/// the model, which has no speed control.
///
/// Compiled only when FluidAudio is linked (the app targets), like the
/// transcriber in `LocalVoiceEngine.swift`; `TTSService`'s routing is what
/// the tests exercise, through `NeuralSpeechSynthesizing`.
@MainActor
internal final class PocketTtsSpeechEngine: NeuralSpeechSynthesizing {
    internal var onStateChange: ((NeuralSpeechState) -> Void)?
    internal var onEvent: ((NeuralSpeechEvent) -> Void)?

    internal private(set) var state: NeuralSpeechState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private struct Utterance {
        let id: UUID
        let text: String
    }

    private let manager: PocketTtsManager
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    /// What the model produces: 24 kHz mono float. The mixer resamples to the
    /// output device.
    private let format: AVAudioFormat?
    private var graphBuilt = false

    private var queue: [Utterance] = []
    /// Utterances handed in and not yet reported finished or failed, in order.
    private var inFlight: [UUID] = []
    private var worker: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    /// Bumped by `stop()`. A render loop or a player callback from before the
    /// bump belongs to speech that was silenced, and is dropped.
    private var generation = 0
    private var isPaused = false

    internal init() {
        manager = PocketTtsManager()
        format = AVAudioFormat(
            standardFormatWithSampleRate: Double(PocketTtsConstants.audioSampleRate),
            channels: 1
        )
    }

    // MARK: - Loading

    internal func prepare() {
        guard state != .ready, prepareTask == nil else { return }
        state = .preparing
        // Share the process-wide MLX cache cap with the local chat model; the
        // TTS model streams through the same buffer pool.
        MLXMemoryConfig.configureIfNeeded()
        let manager = self.manager
        prepareTask = Task { [weak self] in
            do {
                try await manager.initialize()
                self?.state = .ready
                log.info("PocketTTS ready")
            } catch {
                log.error("PocketTTS load failed: \(error.localizedDescription)")
                self?.state = .failed(error.localizedDescription)
            }
            self?.prepareTask = nil
        }
    }

    // MARK: - Speaking

    internal func speak(_ text: String, id: UUID, rate: Double) {
        guard state.isReady else {
            onEvent?(.failed(id, "The neural voice isn't loaded."))
            return
        }
        timePitch.rate = Float(min(max(rate, 0.5), 2.0))
        inFlight.append(id)
        queue.append(Utterance(id: id, text: text))
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.render(next)
            }
            self?.worker = nil
        }
    }

    /// Stream one utterance into the player. One buffer is held back so the
    /// last one can carry the `finished` callback; the first carries `started`.
    private func render(_ utterance: Utterance) async {
        let myGeneration = generation
        do {
            try startAudioIfNeeded()
            let stream = try await manager.synthesizeStreaming(text: utterance.text)
            var pending: AVAudioPCMBuffer?
            var announcedStart = false
            for try await frame in stream {
                guard generation == myGeneration else { return }
                guard let buffer = makeBuffer(frame.samples) else { continue }
                if let held = pending {
                    schedule(held, id: utterance.id, announcesStart: !announcedStart, isLast: false, generation: myGeneration)
                    announcedStart = true
                }
                pending = buffer
            }
            guard generation == myGeneration else { return }
            if let held = pending {
                schedule(held, id: utterance.id, announcesStart: !announcedStart, isLast: true, generation: myGeneration)
            } else {
                complete(utterance.id)
            }
        } catch {
            guard generation == myGeneration else { return }
            log.error("PocketTTS synthesis failed: \(error.localizedDescription)")
            inFlight.removeAll { $0 == utterance.id }
            onEvent?(.failed(utterance.id, error.localizedDescription))
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, id: UUID, announcesStart: Bool, isLast: Bool, generation: Int) {
        // Completion handlers arrive on the render thread; only the identity
        // and the flags cross back to the main actor.
        let callbackType: AVAudioPlayerNodeCompletionCallbackType = isLast ? .dataPlayedBack : .dataRendered
        if announcesStart || isLast {
            player.scheduleBuffer(buffer, completionCallbackType: callbackType) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if announcesStart { self.onEvent?(.started(id)) }
                    if isLast { self.complete(id) }
                }
            }
        } else {
            player.scheduleBuffer(buffer)
        }
        if !player.isPlaying, !isPaused {
            player.play()
        }
    }

    private func complete(_ id: UUID) {
        inFlight.removeAll { $0 == id }
        onEvent?(.finished(id))
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        _ = UnsafeMutableBufferPointer(start: channel, count: samples.count).initialize(fromContentsOf: samples)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    // MARK: - Audio graph

    private func startAudioIfNeeded() throws {
        if !graphBuilt {
            engine.attach(player)
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            graphBuilt = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: - Transport

    internal func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        queue.removeAll()
        player.stop()
        isPaused = false
        if engine.isRunning { engine.stop() }
        let silenced = inFlight
        inFlight.removeAll()
        for id in silenced {
            onEvent?(.finished(id))
        }
    }

    @discardableResult
    internal func pause() -> Bool {
        guard player.isPlaying, !isPaused else { return false }
        player.pause()
        isPaused = true
        return true
    }

    @discardableResult
    internal func resume() -> Bool {
        guard isPaused else { return false }
        isPaused = false
        player.play()
        return true
    }
}
#endif
