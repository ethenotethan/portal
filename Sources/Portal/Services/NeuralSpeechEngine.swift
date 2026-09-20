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
/// for a conversation: it phrases each sentence naturally rather than shaping
/// intonation once per paragraph, which is what made the system voice feel
/// uncanny in hands-free replies.
///
/// Each utterance is one `synthesizeStreaming` call. Rather than piping frames
/// straight into the player as they arrive, the sentence is buffered in full
/// and only then handed to the player as one contiguous run: PocketTTS's mimi
/// decoder is CPU-only and does not reliably generate faster than it plays on
/// every machine, so a player started on a thin pre-roll underruns — audibly
/// stutters — the moment generation dips below real time. Buffering first
/// trades a little onset latency (one short sentence's synthesis) for playback
/// that cannot stutter mid-sentence. The next sentence is synthesized while
/// this one plays and scheduled onto the still-running player, so a multi-
/// sentence reply stays gapless when generation keeps up. `started` fires as
/// the first buffer renders, `finished` as the last finishes playing. Speaking
/// rate is applied with a time-pitch unit rather than by the model, which has
/// no speed control.
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

    /// Synthesize one utterance in full, then schedule it as one contiguous run
    /// and start the player. Buffering the whole sentence before playing any of
    /// it is what stops the mid-sentence stutter: a CPU-only decoder that dips
    /// below real time can't starve a player that already holds the entire
    /// sentence. The first buffer carries `started`; the last carries
    /// `finished`.
    private func render(_ utterance: Utterance) async {
        let myGeneration = generation
        // Pace instrumentation: how much audio the model generated versus the
        // wall-clock time it took. Below ~1× real time the model can't stream
        // faster than it plays — the reason this path buffers rather than
        // pipes. Logged once per sentence, so it's cheap.
        let startedAt = ContinuousClock.now
        var buffers: [AVAudioPCMBuffer] = []
        var generatedFrames: AVAudioFrameCount = 0
        do {
            try startAudioIfNeeded()
            let stream = try await manager.synthesizeStreaming(text: utterance.text, voice: voice)
            for try await frame in stream {
                guard generation == myGeneration else { return }
                guard let buffer = makeBuffer(frame.samples) else { continue }
                generatedFrames += buffer.frameLength
                buffers.append(buffer)
            }
            guard generation == myGeneration else { return }
            logSynthPace(frames: generatedFrames, since: startedAt)
            guard !buffers.isEmpty else { complete(utterance.id); return }
            for (index, buffer) in buffers.enumerated() {
                schedule(
                    buffer,
                    id: utterance.id,
                    announcesStart: index == 0,
                    isLast: index == buffers.count - 1,
                    generation: myGeneration
                )
            }
            // Kick the player once. It stays running across sentences, so the
            // next sentence's buffers simply extend the queue behind this one.
            if !player.isPlaying, !isPaused { player.play() }
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
    }

    private func complete(_ id: UUID) {
        inFlight.removeAll { $0 == id }
        onEvent?(.finished(id))
    }

    /// Emit the just-finished utterance's generation pace. A comfortable stream
    /// runs several times real time; a value near or below 1× is the reply
    /// stuttering because the model couldn't stay ahead of playback — logged
    /// loudly so a "choppy every now and then" report has a number behind it.
    private func logSynthPace(frames: AVAudioFrameCount, since start: ContinuousClock.Instant) {
        guard frames > 0 else { return }
        let elapsed = ContinuousClock.now - start
        let wallSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard wallSeconds > 0 else { return }
        let audioSeconds = Double(frames) / Double(PocketTtsConstants.audioSampleRate)
        let realtimeFactor = audioSeconds / wallSeconds
        let detail = String(
            format: "%.2f× real time (%.2fs audio in %.2fs)",
            realtimeFactor, audioSeconds, wallSeconds
        )
        if realtimeFactor < 1.3 {
            log.warning("PocketTTS pace \(detail, privacy: .public) — playback may glitch")
        } else {
            log.debug("PocketTTS pace \(detail, privacy: .public)")
        }
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
                do {
                    try await Task.sleep(for: .milliseconds(18))
                } catch {
                    return  // cancelled — a new reply took over; it restores volume
                }
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
