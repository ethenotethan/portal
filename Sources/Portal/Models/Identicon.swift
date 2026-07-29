import SwiftUI

/// A deterministic, GitHub-style symmetric avatar generated from a seed string
/// (a gateway's UUID). Same seed → same picture, every launch, on every device —
/// so a gateway with no uploaded photo still gets a stable, recognizable face.
///
/// The seed is hashed with FNV-1a (a *stable* hash — `Swift.Hasher` is salted
/// per process, so it can't be used for anything persistent). The hash drives
/// both a hue for the foreground color and a 5×5 fill pattern mirrored across
/// the vertical axis (so only the left 3 columns are "random").
internal enum Identicon {

    /// Number of cells per side of the identicon grid.
    private static let gridSize = 5

    /// FNV-1a 64-bit — a small, stable, well-distributed string hash. Unlike
    /// `Hasher`, its output does not vary between process launches, which is
    /// exactly what a persisted-looking avatar needs.
    internal static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The accent hue (0…1) derived from the seed — used for the filled cells.
    internal static func hue(for seed: String) -> Double {
        Double(stableHash(seed) % 360) / 360.0
    }

    /// The mirrored 5×5 fill grid. `true` == filled with the foreground color.
    /// Only the left `ceil(gridSize/2)` columns are derived from the hash; the
    /// right columns mirror them, giving the classic symmetric identicon look.
    internal static func grid(for seed: String) -> [[Bool]] {
        let hash = stableHash(seed)
        let halfWidth = (gridSize + 1) / 2  // 3 for a 5-wide grid
        var cells = Array(
            repeating: Array(repeating: false, count: gridSize),
            count: gridSize
        )
        var bit = 0
        for row in 0..<gridSize {
            for col in 0..<halfWidth {
                // Pull one bit of the hash per left-half cell (25 bits max,
                // well within 64). Even bit → filled.
                let filled = (hash >> UInt64(bit % 64)) & 1 == 0
                bit += 1
                cells[row][col] = filled
                cells[row][gridSize - 1 - col] = filled  // mirror
            }
        }
        return cells
    }
}

/// Renders an `Identicon` for a seed as a rounded square avatar. Drop-in for the
/// persona avatar when no uploaded image exists.
internal struct IdenticonView: View {
    internal let seed: String
    internal var size: CGFloat = 28

    private var grid: [[Bool]] { Identicon.grid(for: seed) }
    private var foreground: Color {
        Color(hue: Identicon.hue(for: seed), saturation: 0.55, brightness: 0.75)
    }
    private var background: Color {
        Color(hue: Identicon.hue(for: seed), saturation: 0.16, brightness: 0.94)
    }

    // `nonisolated` so `Persona`'s nonisolated computed `avatar`/`bubbleAvatar`
    // can build the identicon without hopping to the main actor (a plain value
    // init that touches no actor state).
    nonisolated internal init(seed: String, size: CGFloat = 28) {
        self.seed = seed
        self.size = size
    }

    internal var body: some View {
        let count = grid.count
        Canvas { context, canvasSize in
            let cell = min(canvasSize.width, canvasSize.height) / CGFloat(count)
            context.fill(
                Path(CGRect(origin: .zero, size: canvasSize)),
                with: .color(background)
            )
            for row in 0..<count {
                for col in 0..<count where grid[row][col] {
                    let rect = CGRect(
                        x: CGFloat(col) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(foreground))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
