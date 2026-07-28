import Foundation
import SwiftUI
@testable import Portal

/// Headless View-snapshot support for the snapshot gate.
///
/// SwiftUI renders to a PNG in-process via `ImageRenderer` (macOS 13+) — no
/// host app, no UI-test target, no third-party dependency. Renders are
/// byte-deterministic on a given machine, so a committed golden PNG is a stable
/// reference *for the machine that wrote it*.
///
/// The catch, and why goldens are CI-generated (not committed from a dev Mac):
/// font hinting, antialiasing, and default fonts differ between machines, so a
/// locally-recorded golden would spuriously fail against the CI runner. The
/// golden is therefore recorded ON CI (`SNAPSHOT_RECORD=1`) and committed from
/// that artifact; verification then compares against a render from the *same*
/// environment. A small per-pixel tolerance still absorbs minor OS drift.
internal enum ViewSnapshot {

    /// Where committed golden PNGs live, relative to the repo root. Resolved
    /// from this file's location so it works regardless of the test's CWD.
    internal static var goldenDir: URL {
        // .../Tests/PortalTests/Support/ViewSnapshot.swift → repo root is 4 up.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent()  // Support
            .deletingLastPathComponent()                      // PortalTests
            .deletingLastPathComponent()                      // Tests
            .deletingLastPathComponent()                      // repo root
        return repoRoot.appendingPathComponent("Tests/PortalTests/__Snapshots__", isDirectory: true)
    }

    /// True when the suite should (re)write goldens instead of verifying —
    /// set by the CI record job, never in normal runs.
    internal static var isRecording: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }

    /// Render a view to PNG at a fixed size and scale. Fixed inputs keep the
    /// output deterministic; `.frame` pins layout so a view with no intrinsic
    /// size still produces a stable image.
    @MainActor
    internal static func png(_ view: some View, size: CGSize, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return data
    }

    /// Result of comparing a fresh render against the committed golden.
    internal enum Outcome: Equatable {
        case recorded                    // wrote/updated the golden (record mode)
        case match                       // within tolerance
        case missingGolden               // no golden committed yet
        case mismatch(fraction: Double)  // fraction of pixels beyond tolerance
        case renderFailed
    }

    /// Verify `view` against golden `name`, or record it when SNAPSHOT_RECORD=1.
    ///
    /// - perPixelTolerance: 0…1 channel-difference below which two pixels are
    ///   "equal" — absorbs sub-integer AA drift between otherwise-identical
    ///   environments.
    /// - maxDifferingFraction: fraction of pixels allowed to exceed the
    ///   per-pixel tolerance before it's a mismatch.
    @MainActor
    internal static func verify(
        _ view: some View,
        name: String,
        size: CGSize,
        perPixelTolerance: Double = 0.02,
        maxDifferingFraction: Double = 0.01
    ) -> Outcome {
        guard let fresh = png(view, size: size) else { return .renderFailed }
        let goldenURL = goldenDir.appendingPathComponent("\(name).png")

        if isRecording {
            try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
            do {
                try fresh.write(to: goldenURL, options: .atomic)
                return .recorded
            } catch {
                return .renderFailed
            }
        }

        guard let goldenData = try? Data(contentsOf: goldenURL) else {
            return .missingGolden
        }
        guard let diff = differingFraction(goldenData, fresh, perPixelTolerance: perPixelTolerance) else {
            return .renderFailed
        }
        return diff <= maxDifferingFraction ? .match : .mismatch(fraction: diff)
    }

    /// Fraction of pixels whose max channel difference exceeds the tolerance.
    /// Returns nil if either image can't be decoded or dimensions differ (a
    /// dimension change is itself a real regression the caller treats as such).
    private static func differingFraction(_ a: Data, _ b: Data, perPixelTolerance: Double) -> Double? {
        guard let ra = NSBitmapImageRep(data: a), let rb = NSBitmapImageRep(data: b) else { return nil }
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh else {
            return 1.0  // size changed → maximally different
        }
        guard let pa = ra.bitmapData, let pb = rb.bitmapData else { return nil }
        let w = ra.pixelsWide, h = ra.pixelsHigh
        let spp = ra.samplesPerPixel
        guard rb.samplesPerPixel == spp else { return 1.0 }
        let rowA = ra.bytesPerRow, rowB = rb.bytesPerRow
        let thresh = perPixelTolerance * 255.0
        var differing = 0
        let total = w * h
        for y in 0..<h {
            for x in 0..<w {
                let oa = y * rowA + x * spp
                let ob = y * rowB + x * spp
                var maxDelta = 0.0
                for c in 0..<spp {
                    let delta = abs(Double(pa[oa + c]) - Double(pb[ob + c]))
                    if delta > maxDelta { maxDelta = delta }
                }
                if maxDelta > thresh { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }
}
