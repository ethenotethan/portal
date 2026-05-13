import SwiftUI
import BeautifulMermaid
import os

private let log = Logger(
    subsystem: "com.researchoors.HermesNative",
    category: "MermaidDiagramView"
)

/// Renders a Mermaid diagram natively using BeautifulMermaid.
/// Works around a macOS coordinate-system bug by manually flipping the Y-axis.
struct MermaidDiagramView: View {
    let mermaidCode: String

    var body: some View {
        NativeMermaidRenderer(source: mermaidCode)
    }
}

// MARK: - Native Renderer

private struct NativeMermaidRenderer: View {
    let source: String
    @State private var image: PlatformImage?
    @State private var errorText: String?

    /// Strips markdown fences and trims whitespace.
    private var cleanedSource: String {
        source
            .replacingOccurrences(of: "```mermaid", with: "")
            .replacingOccurrences(of: "```flowchart", with: "")
            .replacingOccurrences(of: "```sequenceDiagram", with: "")
            .replacingOccurrences(of: "```stateDiagram", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let image {
                ZoomableDiagram(image: image)
            } else if let error = errorText {
                ErrorCard(error: error, source: cleanedSource)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Rendering diagram…")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
                .onAppear(perform: render)
            }
        }
    }

    private func render() {
        let code = cleanedSource
        guard !code.isEmpty else {
            errorText = "Empty source after cleaning fences"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Parse + layout via BeautifulMermaid.
                let positioned = try MermaidRenderer.layout(code)
                guard let img = renderPositioned(positioned, scale: 2.0) else {
                    DispatchQueue.main.async {
                        errorText = "renderPositioned returned nil"
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.image = img
                }
            } catch {
                DispatchQueue.main.async {
                    errorText = "\(error.localizedDescription)\n\nCode:\n\(code.prefix(200))"
                }
                log.error("Native mermaid failed: \(error.localizedDescription)")
            }
        }
    }

    /// Draws a PositionedGraph into a new CGContext with the correct Y-axis flip for macOS.
    private func renderPositioned(_ positioned: PositionedGraph, scale: CGFloat) -> PlatformImage? {
        let bounds = CGRect(
            x: 0, y: 0,
            width: max(1, positioned.width),
            height: max(1, positioned.height)
        )
        let pixelSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let w = Int(pixelSize.width)
        let h = Int(pixelSize.height)
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }

        // Background fill
        ctx.setFillColor(nativeTheme.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pixelSize))

        // Retina scale
        ctx.scaleBy(x: scale, y: scale)

        // Y-axis flip: DiagramRenderer assumes y=0 at top (UIKit) but
        // raw CGContext on macOS has y=0 at bottom (AppKit).
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        // Render
        DiagramRenderer(theme: nativeTheme).render(positioned, in: ctx, bounds: bounds)

        guard let cgImage = ctx.makeImage() else { return nil }

        #if os(macOS)
        return NSImage(cgImage: cgImage, size: bounds.size)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

// MARK: - Zoomable Diagram

/// Wraps a rendered diagram image with pinch-to-zoom and drag-to-pan.
private struct ZoomableDiagram: View {
    let image: PlatformImage

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 0.5
    private let maxScale: CGFloat = 8.0

    var body: some View {
        GeometryReader { geo in
            platformImageView(for: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3)) {
                        scale = 1.0
                        offset = .zero
                        lastScale = 1.0
                        lastOffset = .zero
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let newScale = lastScale * value
                            scale = min(max(newScale, minScale), maxScale)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if scale != 1.0 || offset != .zero {
                        Text("\(Int(scale * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.surface.opacity(0.9), in: Capsule())
                            .padding(8)
                    }
                }
        }
    }
}

// MARK: - Error Card

private struct ErrorCard: View {
    let error: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Diagram render failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Text(error)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .overlay(Theme.border.opacity(0.5))

            Text(source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(8)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Theme

private let nativeTheme = DiagramTheme(
    background: bmColor(hex: "1a1a1a"),
    foreground: bmColor(hex: "f0f0f0"),
    line: bmColor(hex: "7c7cff"),
    accent: bmColor(hex: "7c7cff"),
    muted: bmColor(hex: "666666"),
    surface: bmColor(hex: "2a2a2a"),
    border: bmColor(hex: "3a3a3a")
)

// MARK: - Helpers

private func platformImageView(for image: PlatformImage) -> Image {
    #if os(macOS)
    Image(nsImage: image)
    #else
    Image(uiImage: image)
    #endif
}

private func bmColor(hex: String) -> BMColor {
    let sanitized = hex.replacingOccurrences(of: "#", with: "")
    var rgb: UInt64 = 0
    Scanner(string: sanitized).scanHexInt64(&rgb)
    return BMColor(
        red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
        green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
        blue: CGFloat(rgb & 0x0000FF) / 255.0,
        alpha: 1.0
    )
}
