import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "LocalChatService")

/// Which on-device model backs local discussions.
///
/// Ordered smallest-first. The lineup is picked for *spoken* use, which is a
/// narrower job than "best local model": the reply has to start within about a
/// second and then out-pace speech (~6 tokens/sec), so decode throughput and a
/// short time-to-first-token matter more than benchmark scores, and a model that
/// reasons at length by default is actively bad — the user sits in silence while
/// it thinks. That is why two mixture-of-experts models are here: they activate
/// a fraction of their weights per token, so they answer like a small model
/// while knowing like a large one.
///
/// Each case owns its own size, character, and memory floor because that is the
/// whole decision the user is making. The MLX configuration they map to lives in
/// `LocalChatEngine.swift` — this layer stays free of ML imports so it can be
/// unit-tested.
internal enum LocalChatModel: String, CaseIterable, Identifiable, Sendable {
    case gemma3_1b
    case qwen3_1_7b
    case qwen3_4b
    case lfm2_8b_a1b
    case qwen3_8b
    case qwen3_30b_a3b

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .gemma3_1b: return "Gemma 3 1B"
        case .qwen3_1_7b: return "Qwen3 1.7B"
        case .qwen3_4b: return "Qwen3 4B"
        case .lfm2_8b_a1b: return "LFM2 8B-A1B"
        case .qwen3_8b: return "Qwen3 8B"
        case .qwen3_30b_a3b: return "Qwen3 30B-A3B"
        }
    }

    /// The Hugging Face repo this maps to. Duplicated from the MLX registry
    /// deliberately: this layer has to name the repo without importing MLX, both
    /// to stay testable and so `LocalModelCacheScanner` can tell a downloaded
    /// model from a pending one on a build with no engine. `LocalChatEngine`'s
    /// mapping is the source of truth, and a test pins the two together.
    internal var repositoryID: String {
        switch self {
        case .gemma3_1b: return "mlx-community/gemma-3-1b-it-qat-4bit"
        case .qwen3_1_7b: return "mlx-community/Qwen3-1.7B-4bit"
        case .qwen3_4b: return "mlx-community/Qwen3-4B-4bit"
        case .lfm2_8b_a1b: return "mlx-community/LFM2-8B-A1B-3bit-MLX"
        case .qwen3_8b: return "mlx-community/Qwen3-8B-4bit"
        case .qwen3_30b_a3b: return "mlx-community/Qwen3-30B-A3B-4bit"
        }
    }

    /// Total repo size, as Hugging Face reports it. Used for two things: telling
    /// the user what a pick costs, and deciding whether what's on disk is a whole
    /// model or an interrupted download.
    internal var downloadBytes: Int64 {
        switch self {
        case .gemma3_1b: return 730_000_000
        case .qwen3_1_7b: return 970_000_000
        case .qwen3_4b: return 2_260_000_000
        case .lfm2_8b_a1b: return 4_170_000_000
        case .qwen3_8b: return 4_610_000_000
        case .qwen3_30b_a3b: return 17_170_000_000
        }
    }

    /// Approximate download size, shown in Settings so a pick isn't a surprise
    /// multi-gigabyte wait on the first spoken question.
    internal var downloadSize: String {
        "~" + ByteCountLabel.gigabytes(downloadBytes)
    }

    internal var detail: String {
        switch self {
        case .gemma3_1b:
            return "Instant and shallow. Skill summaries already use it, so there's usually nothing to download."
        case .qwen3_1_7b:
            return "The smartest model that still fits an 8 GB Mac. Fine for \"which option, and why\"."
        case .qwen3_4b:
            return "The balance point: follows an architecture argument and still answers in about a second."
        case .lfm2_8b_a1b:
            return "Mixture-of-experts: 8B of breadth, 1.5B active, so it talks back faster than a 2B. Weaker on deep code detail."
        case .qwen3_8b:
            return "The strongest dense model that still keeps pace with speech. Heaviest first token."
        case .qwen3_30b_a3b:
            return "3.3B active out of 30B — the sharpest option here, and still faster than you can listen. Wants real headroom."
        }
    }

    /// Unified memory below which this is a bad idea: the weights, the KV cache,
    /// the speech models and the app share one pool, and overcommitting it trades
    /// a slow reply for a swapping machine.
    internal var minimumMemoryGB: Int {
        switch self {
        case .gemma3_1b, .qwen3_1_7b: return 8
        case .qwen3_4b: return 12
        case .lfm2_8b_a1b, .qwen3_8b: return 16
        case .qwen3_30b_a3b: return 32
        }
    }

    /// Reasoning-by-default models are told to skip the monologue: in a spoken
    /// exchange the user is waiting in silence while it thinks, and the block is
    /// discarded before display anyway (see `ThinkBlockFilter`). All four Qwen3
    /// releases honour the `/no_think` soft switch; Gemma and LFM2 have no
    /// thinking mode to switch off.
    internal var promptSuffix: String {
        switch self {
        case .qwen3_1_7b, .qwen3_4b, .qwen3_8b, .qwen3_30b_a3b: return " /no_think"
        case .gemma3_1b, .lfm2_8b_a1b: return ""
        }
    }

    /// Whether this machine can hold the model without fighting itself.
    internal func fits(_ hardware: HardwareProfile) -> Bool {
        hardware.memoryGB >= minimumMemoryGB
    }

    /// The best pick for a given machine — the default on first run, and what
    /// Settings offers as the recommendation.
    ///
    /// Deliberately one tier below "the biggest thing that fits": the discussion
    /// runs *alongside* the editor, the agent, and two speech models, and a
    /// reply that arrives late is worse than one that arrives a little dumber.
    internal static func recommended(for hardware: HardwareProfile) -> LocalChatModel {
        let byMemory = recommendedByMemory(hardware.memoryGB)
        // Memory says what fits; the chip tier says how fast it will talk. A base
        // M-series has roughly a third of a Max's memory bandwidth, and decode is
        // bandwidth-bound, so a dense model that a 32 GB base Mac mini can hold
        // still answers slower than the user reads. Cap those machines at the
        // mixture-of-experts model, which only reads its active experts per token.
        guard hardware.tier == .base, isHeavier(byMemory, than: .lfm2_8b_a1b) else { return byMemory }
        return .lfm2_8b_a1b
    }

    /// The memory-only tiering, deliberately one rung below "the biggest thing
    /// that fits" for the reason above.
    private static func recommendedByMemory(_ memoryGB: Int) -> LocalChatModel {
        switch memoryGB {
        case ..<12: return .qwen3_1_7b
        case 12..<18: return .qwen3_4b
        case 18..<32: return .lfm2_8b_a1b
        case 32..<48: return .qwen3_8b
        default: return .qwen3_30b_a3b
        }
    }

    /// Lineup order, which is smallest-first, as the comparison — memory floors
    /// tie (LFM2 and Qwen3 8B both want 16 GB) and cannot order the two.
    private static func isHeavier(_ model: LocalChatModel, than other: LocalChatModel) -> Bool {
        guard let lhs = allCases.firstIndex(of: model),
              let rhs = allCases.firstIndex(of: other) else { return false }
        return lhs > rhs
    }

    /// What to select on first run, before the user has expressed any preference.
    ///
    /// Not simply `recommended(for:)`, because opting in now starts the download
    /// immediately: on a 48 GB Mac that would fire off 17 GB the moment the toggle
    /// flips. Weights already on disk — often Gemma, which skill summaries fetch —
    /// make the feature work in seconds instead, and Settings still offers the
    /// hardware's pick with its size next to it.
    internal static func startingChoice(
        hardware: HardwareProfile,
        downloaded: Set<LocalChatModel>
    ) -> LocalChatModel {
        let ideal = recommended(for: hardware)
        if downloaded.contains(ideal) { return ideal }
        // The best already-present model this machine can hold; "best" being
        // lineup order, which is roughly capability order.
        let present = allCases.filter { downloaded.contains($0) && $0.fits(hardware) }
        return present.last ?? ideal
    }
}

internal enum LocalChatError: LocalizedError, Equatable {
    case unavailable
    case loadFailed(String)
    case emptyResponse

    internal var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device discussion isn't available in this build"
        case .loadFailed(let detail):
            return detail
        case .emptyResponse:
            return "The local model returned nothing"
        }
    }
}

/// Text-generation seam for local discussions. The real MLX implementation lives
/// in `LocalChatEngine.swift`; tests inject a fake and drive the whole service
/// without a model download.
///
/// Deltas come back as an `AsyncThrowingStream` rather than through a callback
/// on purpose: the service consumes it sequentially on the main actor, so
/// streamed text can never arrive out of order (which a `@Sendable` callback
/// hopping to the main actor per token does not guarantee).
internal protocol LocalChatGenerating: Sendable {
    /// Download (first use) and load the model. Idempotent per model.
    func prepare(model: LocalChatModel) async throws
    /// Stream one reply. The engine keeps a chat session alive across calls with
    /// matching `instructions`, so the exchange accumulates history; changing
    /// instructions (a new discussion) starts a fresh session.
    func stream(instructions: String, prompt: String, model: LocalChatModel) -> AsyncThrowingStream<String, Error>
    /// Drop the current session's history. The loaded weights stay resident.
    func endSession() async
}

/// The slice of the local-chat service `ChatViewModel` drives, as a protocol so
/// the routing can be tested with a fake — no model, no singleton.
@MainActor
internal protocol LocalChatControlling: AnyObject {
    /// True when this build can generate locally at all (engine linked, and a
    /// platform where keeping weights resident is safe).
    var isAvailable: Bool { get }
    /// User opt-in. Off by default.
    var isEnabled: Bool { get }
    /// Both of the above — the only thing call sites should gate on.
    var isEnabledAndAvailable: Bool { get }
    /// True while the model is downloading or loading into memory.
    var isPreparing: Bool { get }
    /// Last load/generation failure, for the discussion surface to show.
    var lastError: String? { get }
    /// Begin loading in the background; safe to call repeatedly.
    func prepare()
    /// Generate a reply, delivering visible text incrementally on the main
    /// actor. Returns the cleaned full reply.
    func respond(
        instructions: String,
        to prompt: String,
        onDelta: @escaping (String) -> Void
    ) async -> Result<String, Error>
    /// End the exchange — the next `respond` starts with no history.
    func endSession() async
}

extension LocalChatControlling {
    internal var isEnabledAndAvailable: Bool { isEnabled && isAvailable }
}

/// On-device conversation partner for talking through a reply, mirroring how
/// `LocalVoiceService` owns on-device transcription and `TTSService` owns speech.
///
/// Off by default and opt-in (Settings → Speech). Enabled, the "discuss" button
/// on an assistant message opens a spoken side-conversation that runs entirely
/// on this machine: no gateway turn, no tokens billed, nothing added to the
/// session transcript.
///
/// This file is the testable orchestration core — it imports no ML framework and
/// reaches generation only through `LocalChatGenerating`. The MLX implementation
/// lives in `LocalChatEngine.swift`.
@MainActor
internal final class LocalChatService: ObservableObject, LocalChatControlling {
    // A second on-device-model service alongside TTSService/LocalVoiceService,
    // and shaped like them: the model weights are a process-wide resource
    // (gigabytes of Metal buffers) that must not be duplicated per view, and the
    // discuss affordance is reachable from any message bubble. Injectable
    // everywhere it matters — ChatViewModel takes `any LocalChatControlling`.
    // swiftlint:disable:next no_new_singletons
    internal static let shared = LocalChatService()

    internal static let enabledKey = "portal.localChatEnabled"
    internal static let modelKey = "portal.localChatModel"

    @Published internal var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            // Opting in is the moment to pay the download, not the first spoken
            // question: the user is sitting in Settings watching a progress label
            // instead of waiting mid-conversation for gigabytes of weights.
            // Launch stays lazy — `didSet` doesn't fire for the stored value.
            if isEnabled, !oldValue {
                refreshInventory()
                prepare()
            }
        }
    }

    /// Switching models drops the loaded weights and any live session — the next
    /// discussion loads the new one.
    @Published internal var model: LocalChatModel {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model.rawValue, forKey: Self.modelKey)
            // "Ready" was about the old weights, and an error was about loading
            // them — neither survives the switch, and leaving `isReady` set would
            // make `prepare()` skip the new model's load entirely.
            isReady = false
            loadFailed = false
            lastError = nil
            // A load already running is for the model the user just moved off.
            // It also has to be cleared, or `prepare()` folds into it and the new
            // weights never load.
            prepareTask?.cancel()
            prepareTask = nil
            let engine = self.engine
            Task { await engine?.endSession() }
            if isEnabled { prepare() }
        }
    }

    @Published internal private(set) var isPreparing = false
    @Published internal private(set) var lastError: String?
    /// Which models are already on this machine. Starts `.unknown` and is filled
    /// in by a background scan, so nothing here blocks a launch or a view update.
    @Published internal private(set) var inventory: LocalModelInventory = .unknown
    /// True once a `prepare` has completed for the current model, so the surface
    /// can distinguish "warming up" from "ready and just thinking".
    @Published internal private(set) var isReady = false

    private let engine: (any LocalChatGenerating)?
    /// Where the two opt-ins persist. Injected so a test can drive the service
    /// without leaving settings behind in the real app's defaults.
    private let defaults: UserDefaults
    private var prepareTask: Task<Void, Never>?
    /// The last load failed, as distinct from the last *generation* having failed:
    /// only the former means asking again is pointless.
    private var loadFailed = false

    /// What the recommendation and the memory warnings are based on. Injected so
    /// tests can pretend to be an 8 GB Air or a 128 GB Studio.
    internal let hardware: HardwareProfile
    /// Reads the shared Hugging Face cache. Injected so tests scan a temp
    /// directory instead of the developer's real 100 GB of weights.
    private let scanner: LocalModelCacheScanner

    /// Production initializer: wires the default engine, or leaves the service
    /// unavailable when none is linked.
    internal convenience init() {
        self.init(engine: LocalChatService.defaultEngine())
    }

    internal init(
        engine: (any LocalChatGenerating)?,
        defaults: UserDefaults = .standard,
        hardware: HardwareProfile = .current(),
        scanner: LocalModelCacheScanner = .current()
    ) {
        self.engine = engine
        self.defaults = defaults
        self.hardware = hardware
        self.scanner = scanner
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let saved = defaults.string(forKey: Self.modelKey).flatMap(LocalChatModel.init(rawValue:)) {
            self.model = saved
        } else {
            // First run picks by machine rather than by a hardcoded default: the
            // same build has to serve an 8 GB Air and a 128 GB Studio, and the
            // wrong guess is either a needlessly dim conversation or a swapping
            // one. The one scan on the main thread is confined to this path — the
            // default also has to account for what's already downloaded, and by
            // the time an async scan landed the toggle could already have started
            // fetching 17 GB.
            let scan = scanner.scan()
            self.inventory = scan
            self.model = LocalChatModel.startingChoice(hardware: hardware, downloaded: scan.downloadedSet)
        }
    }

    /// Re-read the cache in the background. Called on opt-in, after a load
    /// finishes (the download that just completed should stop reading as pending),
    /// and when the Settings pane appears.
    internal func refreshInventory() {
        let scanner = self.scanner
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) { scanner.scan() }.value
            self?.inventory = scan
        }
    }

    /// MLX generation needs both a linked engine and an Apple Silicon GPU — on
    /// Intel the download would succeed and the load would not.
    internal var isAvailable: Bool { engine != nil && hardware.isAppleSilicon }

    /// The pick for this machine, for Settings to offer.
    internal var recommendedModel: LocalChatModel { LocalChatModel.recommended(for: hardware) }

    /// Start loading in the background. Called the moment the user opts in or
    /// changes model in Settings, and again when a discussion opens, so the first
    /// spoken question doesn't also pay for the weight load.
    internal func prepare() {
        guard isEnabledAndAvailable, prepareTask == nil, !isReady else { return }
        let engine = self.engine
        let model = self.model
        isPreparing = true
        lastError = nil
        loadFailed = false
        prepareTask = Task { [weak self] in
            do {
                try await engine?.prepare(model: model)
                self?.isReady = true
            } catch {
                log.error("Local chat model load failed: \(error.localizedDescription)")
                self?.lastError = error.localizedDescription
                self?.isReady = false
                self?.loadFailed = true
            }
            self?.isPreparing = false
            self?.prepareTask = nil
            // Whatever that load downloaded is on disk now.
            self?.refreshInventory()
        }
    }

    internal func respond(
        instructions: String,
        to prompt: String,
        onDelta: @escaping (String) -> Void
    ) async -> Result<String, Error> {
        guard let engine, isEnabledAndAvailable else { return .failure(LocalChatError.unavailable) }
        // Fold in any in-flight load rather than racing it: two generations
        // triggered before the weights land would otherwise both load.
        await prepareTask?.value
        // A failed *load* is fatal for every turn — asking again just waits for
        // the same missing weights. A failed *generation* is not, so its error is
        // cleared here rather than latching the discussion shut.
        if loadFailed, let lastError { return .failure(LocalChatError.loadFailed(lastError)) }
        lastError = nil

        var filter = ThinkBlockFilter()
        var raw = ""
        do {
            let stream = engine.stream(
                instructions: instructions,
                prompt: prompt + model.promptSuffix,
                model: model
            )
            for try await delta in stream {
                raw += delta
                let visible = filter.feed(delta)
                if !visible.isEmpty { onDelta(visible) }
            }
            let tail = filter.finish()
            if !tail.isEmpty { onDelta(tail) }

            let cleaned = LocalReplyText.clean(raw)
            guard !cleaned.isEmpty else { return .failure(LocalChatError.emptyResponse) }
            isReady = true
            return .success(cleaned)
        } catch is CancellationError {
            // The user talked over the reply, or closed the discussion. Expected,
            // so it must not surface as an error the next turn has to step past.
            return .failure(CancellationError())
        } catch {
            log.warning("Local chat generation failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    internal func endSession() async {
        await engine?.endSession()
    }
}

// MARK: - Default engine wiring

extension LocalChatService {
    #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers) && os(macOS)
    /// macOS only, for the same reason `SkillSummaryService` is: mlx-swift-lm
    /// compiles for iOS (so `canImport` passes there), but keeping multi-gigabyte
    /// weights resident blows iOS's jetsam budget and the app is killed
    /// mid-session — which reads to the user as a random crash.
    internal static func defaultEngine() -> (any LocalChatGenerating)? { MLXLocalChatEngine() }
    #else
    internal static func defaultEngine() -> (any LocalChatGenerating)? { nil }
    #endif
}
