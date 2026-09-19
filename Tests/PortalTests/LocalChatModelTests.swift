import Foundation
import Testing
@testable import Portal

@Suite("Hardware profile")
internal struct HardwareProfileTests {

    @Test("marketing gigabytes, not truncated binary ones")
    internal func roundsGigabytes() {
        // A 16 GB Mac reports 17_179_869_184 bytes; truncating would call it 15
        // and drop the machine a whole recommendation tier.
        #expect(HardwareProfile.gigabytes(fromBytes: 17_179_869_184) == 16)
        #expect(HardwareProfile.gigabytes(fromBytes: 8_589_934_592) == 8)
        #expect(HardwareProfile.gigabytes(fromBytes: 38_654_705_664) == 36)
        #expect(HardwareProfile.gigabytes(fromBytes: 0) == 0)
    }

    @Test("the summary names what the recommendation was based on")
    internal func summarizes() {
        #expect(
            HardwareProfile(memoryGB: 48, chip: "Apple M4 Pro", gpuCores: 20).summary
                == "Apple M4 Pro \u{00B7} 20 GPU cores \u{00B7} 48 GB"
        )
        // Whatever the system won't say is dropped rather than shown as a gap.
        #expect(HardwareProfile(memoryGB: 48, chip: "Apple M4 Pro").summary == "Apple M4 Pro \u{00B7} 48 GB")
        #expect(HardwareProfile(memoryGB: 16, chip: nil).summary == "16 GB")
        #expect(HardwareProfile(memoryGB: 16, chip: "").summary == "16 GB")
        #expect(HardwareProfile(memoryGB: 16, chip: nil, gpuCores: 0).summary == "16 GB")
    }

    @Test("the chip tier is read out of the chip name")
    internal func detectsChipTier() {
        #expect(ChipTier.detect(chip: "Apple M4") == .base)
        #expect(ChipTier.detect(chip: "Apple M4 Pro") == .pro)
        #expect(ChipTier.detect(chip: "Apple M2 Max") == .max)
        #expect(ChipTier.detect(chip: "Apple M1 Ultra") == .ultra)
        // Intel Macs and anything unrecognised claim nothing, so memory decides
        // alone rather than a wrong tier capping the recommendation.
        #expect(ChipTier.detect(chip: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz") == .unknown)
        #expect(ChipTier.detect(chip: nil) == .unknown)
        #expect(ChipTier.detect(chip: "") == .unknown)
        #expect(HardwareProfile(memoryGB: 48, chip: "Apple M4 Max").tier == .max)
    }

    @Test("this machine answers plausibly")
    internal func currentMachineIsSane() {
        let current = HardwareProfile.current()
        // Not asserting values — the suite runs on CI runners and laptops alike.
        // The point is that each probe returns something usable rather than zero.
        #expect(current.memoryGB > 0)
        #expect(LocalChatModel.recommended(for: current).minimumMemoryGB > 0)
        // GPU cores are optional (a VM won't say), but a number, if given, is real.
        #expect((current.gpuCores ?? 1) > 0)
        #expect(!current.summary.isEmpty)
    }
}

@Suite("Local chat model catalog")
internal struct LocalChatModelTests {

    @Test("every model is presentable in the picker")
    internal func everyCaseIsDescribed() {
        for model in LocalChatModel.allCases {
            #expect(!model.label.isEmpty)
            #expect(!model.downloadSize.isEmpty)
            #expect(!model.detail.isEmpty)
            #expect(model.id == model.rawValue)
            #expect(model.minimumMemoryGB >= 8)
        }
        // Six is the whole lineup; a seventh should come with a reason.
        #expect(LocalChatModel.allCases.count == 6)
    }

    @Test("only the hybrid-thinking models get told to skip the monologue")
    internal func noThinkSuffixOnQwenOnly() {
        // Qwen3 reasons by default and honours the /no_think soft switch. Sending
        // it to a model without a thinking mode just leaks the token into speech.
        #expect(LocalChatModel.qwen3_1_7b.promptSuffix == " /no_think")
        #expect(LocalChatModel.qwen3_4b.promptSuffix == " /no_think")
        #expect(LocalChatModel.qwen3_8b.promptSuffix == " /no_think")
        #expect(LocalChatModel.qwen3_30b_a3b.promptSuffix == " /no_think")
        #expect(LocalChatModel.gemma3_1b.promptSuffix.isEmpty)
        #expect(LocalChatModel.lfm2_8b_a1b.promptSuffix.isEmpty)
    }

    @Test("the lineup is ordered smallest-first by memory floor")
    internal func orderedBySize() {
        let floors = LocalChatModel.allCases.map(\.minimumMemoryGB)
        #expect(floors == floors.sorted())
    }

    @Test("recommendations follow unified memory")
    internal func recommendsByMemory() {
        func pick(_ memoryGB: Int) -> LocalChatModel {
            LocalChatModel.recommended(for: HardwareProfile(memoryGB: memoryGB))
        }
        #expect(pick(8) == .qwen3_1_7b)
        #expect(pick(11) == .qwen3_1_7b)
        #expect(pick(16) == .qwen3_4b)
        #expect(pick(18) == .lfm2_8b_a1b)
        #expect(pick(24) == .lfm2_8b_a1b)
        #expect(pick(32) == .qwen3_8b)
        #expect(pick(36) == .qwen3_8b)
        #expect(pick(48) == .qwen3_30b_a3b)
        #expect(pick(128) == .qwen3_30b_a3b)
    }

    @Test("nothing is ever recommended onto a machine it doesn't fit")
    internal func recommendationAlwaysFits() {
        for memoryGB in [8, 12, 16, 18, 24, 32, 36, 48, 64, 96, 128] {
            let hardware = HardwareProfile(memoryGB: memoryGB)
            let pick = LocalChatModel.recommended(for: hardware)
            #expect(pick.fits(hardware), "recommended \(pick.label) for \(memoryGB) GB")
        }
    }

    @Test("a model too big for the machine is flagged, not silently allowed")
    internal func flagsModelsThatDoNotFit() {
        let air = HardwareProfile(memoryGB: 8)
        #expect(LocalChatModel.gemma3_1b.fits(air))
        #expect(LocalChatModel.qwen3_1_7b.fits(air))
        // The user can still pick these; Settings warns instead of hiding them.
        #expect(!LocalChatModel.qwen3_4b.fits(air))
        #expect(!LocalChatModel.qwen3_30b_a3b.fits(air))
        #expect(LocalChatModel.qwen3_30b_a3b.fits(HardwareProfile(memoryGB: 32)))
    }

    @Test("every model names a distinct hub repo, sized in step with the lineup")
    internal func repositoriesAndSizes() {
        var seen: Set<String> = []
        for model in LocalChatModel.allCases {
            // mlx-community, because these are the 4-bit MLX conversions; a
            // typo here reads as "never downloaded" forever.
            #expect(model.repositoryID.hasPrefix("mlx-community/"))
            #expect(!seen.contains(model.repositoryID))
            seen.insert(model.repositoryID)
            #expect(model.downloadBytes > 0)
            #expect(model.downloadSize.hasPrefix("~"))
        }
        // Smallest-first by download too, not just by memory floor.
        let sizes = LocalChatModel.allCases.map(\.downloadBytes)
        #expect(sizes == sizes.sorted())
        #expect(LocalChatModel.gemma3_1b.downloadSize == "~0.7 GB")
    }

    @Test("a base-tier chip is capped at the mixture-of-experts model")
    internal func baseTierPrefersMoE() {
        // A 32 GB base M4 mini has the memory for a dense 8B and about a third of
        // a Max's bandwidth to feed it, so it would answer slower than the user
        // reads. Same memory on a Pro keeps the dense model.
        let mini = HardwareProfile(memoryGB: 32, chip: "Apple M4")
        #expect(LocalChatModel.qwen3_8b.fits(mini))
        #expect(LocalChatModel.recommended(for: mini) == .lfm2_8b_a1b)
        #expect(LocalChatModel.recommended(for: HardwareProfile(memoryGB: 32, chip: "Apple M4 Pro")) == .qwen3_8b)
        // Below the MoE the cap changes nothing — a base chip with 16 GB was
        // already being offered the 4B.
        #expect(LocalChatModel.recommended(for: HardwareProfile(memoryGB: 16, chip: "Apple M4")) == .qwen3_4b)
        #expect(LocalChatModel.recommended(for: HardwareProfile(memoryGB: 24, chip: "Apple M4")) == .lfm2_8b_a1b)
    }

    @Test("the first-run pick uses weights that are already here")
    internal func startingChoicePrefersDownloadedWeights() {
        let studio = HardwareProfile(memoryGB: 64, chip: "Apple M4 Max")
        #expect(LocalChatModel.recommended(for: studio) == .qwen3_30b_a3b)
        // Opting in starts the download, so defaulting to the ideal model here
        // means 17 GB before the first sentence. Gemma is usually already on disk
        // (skill summaries fetch it), and Settings still offers the upgrade.
        #expect(LocalChatModel.startingChoice(hardware: studio, downloaded: [.gemma3_1b]) == .gemma3_1b)
        // The best of what's present, not merely the first.
        #expect(
            LocalChatModel.startingChoice(hardware: studio, downloaded: [.gemma3_1b, .qwen3_8b]) == .qwen3_8b
        )
        // Already have the right model: no reason to settle.
        #expect(
            LocalChatModel.startingChoice(hardware: studio, downloaded: [.gemma3_1b, .qwen3_30b_a3b])
                == .qwen3_30b_a3b
        )
        // Nothing on disk falls back to the hardware's pick.
        #expect(LocalChatModel.startingChoice(hardware: studio, downloaded: []) == .qwen3_30b_a3b)
        // A downloaded model that doesn't fit this machine is not a shortcut.
        let air = HardwareProfile(memoryGB: 8, chip: "Apple M2")
        #expect(LocalChatModel.startingChoice(hardware: air, downloaded: [.qwen3_30b_a3b]) == .qwen3_1_7b)
        #expect(LocalChatModel.startingChoice(hardware: air, downloaded: [.gemma3_1b]) == .gemma3_1b)
    }

    @Test("the recommendation leaves headroom rather than maxing the machine out")
    internal func recommendationIsNotTheBiggestThatFits() {
        // A 24 GB Mac *can* hold Qwen3 8B, but the discussion runs alongside the
        // editor, the agent, and two speech models — so the MoE that answers
        // faster wins.
        let hardware = HardwareProfile(memoryGB: 24)
        #expect(LocalChatModel.qwen3_8b.fits(hardware))
        #expect(LocalChatModel.recommended(for: hardware) == .lfm2_8b_a1b)
    }
}
