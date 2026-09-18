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
        #expect(HardwareProfile(memoryGB: 48, chip: "Apple M4 Pro").summary == "Apple M4 Pro \u{00B7} 48 GB")
        // No chip name is not worth an empty separator.
        #expect(HardwareProfile(memoryGB: 16, chip: nil).summary == "16 GB")
        #expect(HardwareProfile(memoryGB: 16, chip: "").summary == "16 GB")
    }

    @Test("this machine answers plausibly")
    internal func currentMachineIsSane() {
        let current = HardwareProfile.current()
        // Not asserting a value — the suite runs on CI runners and laptops alike.
        // The point is that the probe returns something usable rather than zero.
        #expect(current.memoryGB > 0)
        #expect(LocalChatModel.recommended(for: current).minimumMemoryGB > 0)
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
