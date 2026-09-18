import Foundation

/// What this machine can actually run — the facts that decide which on-device
/// model is a good idea here.
///
/// Unified memory is the binding constraint: weights, the KV cache, the ASR and
/// TTS models, and the app itself all come out of the same pool, so a 4-bit 8B
/// that is merely *possible* on 16 GB and *comfortable* on 32 GB is a different
/// recommendation on each. Kept a plain value type (not a service) so the
/// picking logic is pure and testable — nothing here touches Metal.
internal struct HardwareProfile: Sendable, Equatable {
    /// Total unified/physical memory, rounded to the nearest whole gigabyte the
    /// way Apple markets it (a 16 GB Mac reports 17_179_869_184 bytes).
    internal let memoryGB: Int
    /// Marketing chip name (`Apple M4 Pro`), when the system will tell us.
    internal let chip: String?
    /// MLX generation needs an Apple Silicon GPU; on Intel it would download
    /// gigabytes and then fail at load.
    internal let isAppleSilicon: Bool

    internal init(memoryGB: Int, chip: String? = nil, isAppleSilicon: Bool = true) {
        self.memoryGB = memoryGB
        self.chip = chip
        self.isAppleSilicon = isAppleSilicon
    }

    /// This machine.
    internal static func current() -> HardwareProfile {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return HardwareProfile(
            memoryGB: gigabytes(fromBytes: ProcessInfo.processInfo.physicalMemory),
            chip: sysctlString("machdep.cpu.brand_string"),
            isAppleSilicon: appleSilicon
        )
    }

    /// `Apple M4 Pro · 48 GB`, or just the memory when the chip is unknown —
    /// enough for Settings to show the user what the recommendation was based on.
    internal var summary: String {
        guard let chip, !chip.isEmpty else { return "\(memoryGB) GB" }
        return "\(chip) · \(memoryGB) GB"
    }

    /// Bytes → whole gigabytes, rounded rather than truncated: memory is reported
    /// in binary gigabytes, so 16 GB arrives as 15.99… and must not read as 15.
    internal static func gigabytes(fromBytes bytes: UInt64) -> Int {
        guard bytes > 0 else { return 0 }
        return Int((Double(bytes) / 1_073_741_824).rounded())
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
