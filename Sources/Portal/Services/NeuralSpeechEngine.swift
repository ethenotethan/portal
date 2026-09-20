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
    internal var onOutputLevel: ((Float) -> Void)?

    /// A curated shortlist of the pack's shipped voices. The English pack
    /// carries ~two dozen `<voice>.safetensors`; these are the clearly-named,
    /// distinct ones, so the picker is a choice rather than a wall. All ship in
    /// the one pack download, so any of them resolves locally once loaded.
    internal let availableVoices: [NeuralVoiceOption] = [
        NeuralVoiceOption(id: "alba", name: "Alba"),
        NeuralVoiceOption(id: "michael", name: "Michael"),
        NeuralVoiceOption(id: "anna", name: "Anna"),
        NeuralVoiceOption(id: "george", name: "George"),
        NeuralVoiceOption(id: "eve", name: "Eve"),
        NeuralVoiceOption(id: "jane", name: "Jane"),
        NeuralVoiceOption(id: "giovanni", name: "Giovanni"),
        NeuralVoiceOption(id: "rafael", name: "Rafael"),
        NeuralVoiceOption(id: "vera", name: "Vera"),
        NeuralVoiceOption(id: "charles", name: "Charles")
    ]

    /// The voice the next utterance is synthesized with. Defaults to the model's
    /// own default; `TTSService` pushes the persisted choice in.
    internal var voice: String = PocketTtsConstants.defaultVoice

    /// Persona warmth as a pitch shift in cents, applied through the time-pitch
    /// unit. Kept live so a change while speaking is heard on the next buffer.
    internal var pitch: Float = 0 {
        didSet { timePitch.pitch = pitch }
    }

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
    /// The in-progress soft stop (see `beginFadeOut`). Cancelled the instant new
    /// speech arrives so a reply landing mid-fade is heard at full volume.
    private var fadeTask: Task<Void, Never>?
    /// Bumped by `stop()`. A render loop or a player callback from before the
    /// bump belongs to speech that was silenced, and is dropped.
    private var generation = 0
    private var isPaused = false
    /// Audio scheduled for the current playback session but not yet started.
    /// The player waits for this to cross `prerollFrames` before it begins, so
    /// the model — slowest on its very first inference frames — builds a lead
    /// over the playout cursor instead of starving it. Reset on `stop()`; only
    /// consulted while the player is idle, so a stale value between sessions is
    /// harmless.
    private var scheduledUnplayedFrames: AVAudioFrameCount = 0
    /// ~300 ms of pre-roll: enough to absorb the slow onset frames without
    /// adding latency a listener would notice on a spoken reply.
    private static let prerollSeconds = 0.3
    private var prerollFrames: AVAudioFrameCount {
        AVAudioFrameCount(Double(PocketTtsConstants.audioSampleRate) * Self.prerollSeconds)
    }

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
                // One throwaway synth before we report ready: the first
                // inference is markedly slower than steady state (kernel
                // compilation, ANE/GPU spin-up), and that slow onset is what
                // starves the player at the start of the first real reply.
                // Consume the frames, play none — so the cold pass is paid
                // here, once, not on the user's first spoken turn.
                do {
                    let warmUp = try await manager.synthesizeStreaming(text: "Ready.")
                    for try await _ in warmUp {}
                } catch {
                    log.debug("PocketTTS warm-up skipped: \(error.localizedDescription)")
                }
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
        // A reply that arrives while a previous stop is still fading in cancels
        // the fade and restores full volume, so it isn't heard through a dip.
        fadeTask?.cancel()
        fadeTask = nil
        player.volume = 1
        timePitch.rate = Float(min(max(rate, 0.5), 2.0))
        timePitch.pitch = pitch
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
            let stream = try await manager.synthesizeStreaming(text: utterance.text, voice: voice)
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
            scheduledUnplayedFrames += buffer.frameLength
            // Hold playback until a pre-roll cushion has queued (or the
            // utterance is already complete — a one-buffer reply can't
            // pre-roll). This is what keeps the onset from stuttering while
            // the model is still spinning up.
            if isLast || scheduledUnplayedFrames >= prerollFrames {
                player.play()
            }
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
            installOutputMeter()
            graphBuilt = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Meter the audio actually leaving the mixer so the orb breathes with the
    /// assistant's voice in real time — read at the output rather than at
    /// scheduling, so it's synced to what's heard, not to what the model has
    /// generated ~300 ms ahead. Installed once with the graph; the tap is cheap
    /// and idles at ~0 between utterances.
    private func installOutputMeter() {
        let mixer = engine.mainMixerNode
        let onLevel = onOutputLevel
        guard onLevel != nil else { return }
        mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { buffer, _ in
            let level = Self.level(of: buffer)
            Task { @MainActor [weak self] in self?.onOutputLevel?(level) }
        }
    }

    /// RMS loudness of an output buffer, mapped from a ~-50…-10 dBFS window into
    /// 0...1 — the same shaping the mic meter uses, so the orb reacts the same
    /// whoever is talking.
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

    // MARK: - Transport

    internal func stop() {
        generation += 1
        let gen = generation
        worker?.cancel()
        worker = nil
        queue.removeAll()
        scheduledUnplayedFrames = 0
        isPaused = false
        let silenced = inFlight
        inFlight.removeAll()
        for id in silenced {
            onEvent?(.finished(id))
        }
        // Soft stop: ramp the player down over ~150 ms rather than cutting it
        // dead, so a barge-in or a tapped Stop ends on a breath instead of a
        // click. The generation bump above already makes every in-flight render
        // and scheduled callback bail, so nothing new queues behind the fade.
        beginFadeOut(generation: gen)
    }

    /// Ramp the player to silence, then tear the engine down. Bails (leaving
    /// `speak` to restore the volume) if a newer generation started meanwhile,
    /// so a reply that lands mid-fade plays at full level.
    private func beginFadeOut(generation gen: Int) {
        fadeTask?.cancel()
        guard player.isPlaying else {
            teardownAudio()
            return
        }
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 8
            let start = self.player.volume
            for step in 1...steps {
                if Task.isCancelled || self.generation != gen { return }
                self.player.volume = start * Float(steps - step) / Float(steps)
                try? await Task.sleep(for: .milliseconds(18))
            }
            if Task.isCancelled || self.generation != gen { return }
            self.teardownAudio()
        }
    }

    private func teardownAudio() {
        player.stop()
        player.volume = 1
        if engine.isRunning { engine.stop() }
        // The output tap stops firing once the engine is down; leave the orb at
        // rest rather than frozen at the last syllable's loudness.
        onOutputLevel?(0)
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
