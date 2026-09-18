import Foundation
#if os(macOS)
import IOKit
#endif

/// Which rung of an Apple Silicon generation a chip sits on.
///
/// It matters because memory bandwidth, not core count, sets decode speed: a
/// base M-series shares roughly 120 GB/s, a Pro doubles that, a Max doubles it
/// again. A dense 8B at 4-bit has to read ~4.6 GB per token, so on a base chip
/// it decodes slower than the user reads — while a mixture-of-experts model
/// reading only its active experts stays comfortable. RAM alone can't see that
/// difference: a base Mac mini can be configured with 32 GB.
internal enum ChipTier: String, Sendable, Equatable, CaseIterable {
    case base
    case pro
    case max
    case ultra
    /// Intel, a virtual machine, or a chip name we don't recognise — assume
    /// nothing and let memory decide alone.
    case unknown

    /// Reads the tier out of the marketing chip name (`Apple M4 Pro`).
    internal static func detect(chip: String?) -> ChipTier {
        guard let chip else { return .unknown }
        let name = chip.lowercased()
        guard name.contains("apple m") else { return .unknown }
        if name.contains(" ultra") { return .ultra }
        if name.contains(" max") { return .max }
        if name.contains(" pro") { return .pro }
        return .base
    }
}

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
    /// GPU cores, when the IO registry will say. Not a throughput number on its
    /// own, but it's the one figure that separates an 8-core base chip from a
    /// 20-core Pro with the same amount of memory.
    internal let gpuCores: Int?

    internal init(
        memoryGB: Int,
        chip: String? = nil,
        isAppleSilicon: Bool = true,
        gpuCores: Int? = nil
    ) {
        self.memoryGB = memoryGB
        self.chip = chip
        self.isAppleSilicon = isAppleSilicon
        self.gpuCores = gpuCores
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
            isAppleSilicon: appleSilicon,
            gpuCores: gpuCoreCount()
        )
    }

    /// Which rung of the Apple Silicon line this chip is on, read from its name.
    internal var tier: ChipTier { ChipTier.detect(chip: chip) }

    /// `Apple M4 Pro · 20 GPU cores · 48 GB`, dropping whichever parts the system
    /// wouldn't tell us — enough for Settings to show what the recommendation was
    /// based on, in the order the numbers matter.
    internal var summary: String {
        var parts: [String] = []
        if let chip, !chip.isEmpty { parts.append(chip) }
        if let gpuCores, gpuCores > 0 { parts.append("\(gpuCores) GPU cores") }
        parts.append("\(memoryGB) GB")
        return parts.joined(separator: " · ")
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
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Decoded rather than read as a C string: sysctl reports a NUL-terminated
        // buffer, and the C-string initializers are deprecated (while the
        // validating replacement needs macOS 15). Failable, so a chip name that
        // somehow isn't UTF-8 reads as "unknown chip" instead of mojibake.
        guard let raw = String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// GPU cores from the IO registry, where the Metal accelerator publishes them.
    ///
    /// There is no API for this — `MTLDevice` exposes a name and a memory budget
    /// but not a core count — so the accelerator's `gpu-core-count` property is
    /// the only source. Entirely optional: nil just drops one clause from the
    /// summary, and iOS doesn't run local discussions at all.
    private static func gpuCoreCount() -> Int? {
        #if os(macOS)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let property = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )
            if let count = property?.takeRetainedValue() as? NSNumber, count.intValue > 0 {
                return count.intValue
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}
