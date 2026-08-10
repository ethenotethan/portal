import Foundation
import SwiftUI
import CoreGraphics
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#else
import UIKit
#endif

/// Per-artifact export to Markdown, PDF, or PNG.
///
/// Markdown is the raw artifact content wrapped in a fence with a small
/// metadata header. PDF and PNG render the artifact's SwiftUI kind view
/// offscreen via ``ImageRenderer``, reusing the same dark-theme export views
/// the session PDF pipeline already exercises (maps route through
/// ``MapExportRenderer`` since MapKit's live map rasterizes as an empty box).
@MainActor
internal enum ArtifactExporter {

    internal enum Format: String, CaseIterable {
        case markdown = "Markdown"
        case pdf = "PDF"
        case png = "PNG"

        internal var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .pdf: return "pdf"
            case .png: return "png"
            }
        }

        internal var icon: String {
            switch self {
            case .markdown: return "doc.plaintext"
            case .pdf: return "doc.richtext"
            case .png: return "photo"
            }
        }
    }

    // MARK: - Markdown

    /// Wrap the artifact's raw content in a fence with a metadata header.
    internal static func markdown(for artifact: LivingArtifact) -> String {
        var lines: [String] = []
        lines.append("# \(artifact.displayName)")
        lines.append("")
        lines.append("- **Artifact ID:** `\(artifact.id)`")
        lines.append("- **Kind:** \(artifact.kind)")
        if artifact.rev > 0 {
            lines.append("- **Revision:** \(artifact.rev)")
        }
        lines.append("- **Updated:** \(artifact.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        if !artifact.updatedBy.isEmpty {
            lines.append("- **Updated by:** \(artifact.updatedBy)")
        }
        lines.append("- **Exported:** \(Date().formatted(date: .abbreviated, time: .shortened)) by Portal")
        lines.append("")
        lines.append("---")
        lines.append("")

        if artifact.kind == "markdown" {
            lines.append(artifact.content)
        } else {
            lines.append("```\(artifact.kind)")
            lines.append(artifact.content)
            lines.append("```")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - PDF

    /// Render the artifact as a paginated PDF (dark theme, US Letter).
    /// Returns nil if the rendered view has no measurable content.
    internal static func pdf(for artifact: LivingArtifact) async -> Data? {
        // Maps need MapExportRenderer (MKMapSnapshotter) since MapKit
        // rasterizes as an empty box under ImageRenderer.
        if artifact.kind == "map",
           let spec = MapSpec.parse(artifact.content),
           let image = await MapExportRenderer.renderImage(spec: spec) {
            return mapPDF(image: image, artifact: artifact)
        }

        // Model blocks may contain map views — pre-render those.
        var diagramImages: [String: PlatformImage] = [:]
        if artifact.kind == "model",
           let spec = ModelSpec.parse(artifact.content) {
            for view in spec.views where view.kind == .map {
                if let mapJSON = ModelProjections.mapJSON(spec: spec, view: view),
                   let mapSpec = MapSpec.parse(mapJSON),
                   let image = await MapExportRenderer.renderImage(spec: mapSpec) {
                    diagramImages[mapJSON] = image
                }
            }
        }

        guard let view = exportContent(
            for: artifact,
            diagramImages: diagramImages.isEmpty ? nil : diagramImages
        ) else { return nil }

        let pageSize = CGSize(width: 612, height: 792) // US Letter
        let margin: CGFloat = 40
        let contentWidth = pageSize.width - margin * 2
        let contentHeight = pageSize.height - margin * 2

        // Wrap in dark-theme container with title header.
        let titledView = VStack(alignment: .leading, spacing: 16) {
            exportHeader(for: artifact)
            view
            Spacer(minLength: 0)
        }
        .frame(width: contentWidth)
        .padding(.vertical, 8)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: titledView)
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)

        // Measure total content height.
        var totalHeight: CGFloat = 0
        renderer.render { size, _ in totalHeight = size.height }
        guard totalHeight > 0 else { return nil }

        // Paginate: slice the content into page-height segments.
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: artifact.displayName,
            kCGPDFContextCreator: "Portal",
        ]
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary)
        else { return nil }

        let yRemaining = totalHeight
        var drawnHeight: CGFloat = 0

        while drawnHeight < yRemaining {
            ctx.beginPDFPage(nil)
            #if os(macOS)
            ctx.setFillColor(NSColor(Theme.background).cgColor)
            #else
            ctx.setFillColor(UIColor(Theme.background).cgColor)
            #endif
            ctx.fill(mediaBox)

            let sliceHeight = min(contentHeight, yRemaining - drawnHeight)

            renderer.render { size, draw in
                ctx.saveGState()
                // Flip: PDF origin is bottom-left, SwiftUI is top-left.
                ctx.translateBy(x: margin, y: pageSize.height - margin - sliceHeight)
                // Translate up by the already-drawn portion.
                ctx.translateBy(x: 0, y: drawnHeight)
                ctx.clip(to: CGRect(
                    x: 0, y: -drawnHeight,
                    width: contentWidth, height: sliceHeight
                ))
                draw(ctx)
                ctx.restoreGState()
            }

            ctx.endPDFPage()
            drawnHeight += sliceHeight
        }

        ctx.closePDF()
        return pdfData as Data
    }

    /// Single-image PDF for map snapshots.
    private static func mapPDF(image: PlatformImage, artifact: LivingArtifact) -> Data? {
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 40
        let contentWidth = pageSize.width - margin * 2
        let aspectRatio = image.size.height / image.size.width
        let drawWidth = contentWidth
        let drawHeight = drawWidth * aspectRatio

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: artifact.displayName,
            kCGPDFContextCreator: "Portal",
        ]
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary)
        else { return nil }

        ctx.beginPDFPage(nil)
        #if os(macOS)
        ctx.setFillColor(NSColor(Theme.background).cgColor)
        #else
        ctx.setFillColor(UIColor(Theme.background).cgColor)
        #endif
        ctx.fill(mediaBox)

        // Draw the image centered.
        let drawRect = CGRect(
            x: margin,
            y: (pageSize.height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        #if os(macOS)
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cgImage, in: drawRect)
        }
        #else
        if let cgImage = image.cgImage {
            ctx.draw(cgImage, in: drawRect)
        }
        #endif

        ctx.endPDFPage()
        ctx.closePDF()
        return pdfData as Data
    }

    // MARK: - PNG

    /// Render the artifact to a PNG image. Maps use ``MapExportRenderer``
    /// (MKMapSnapshotter); all other kinds use ``ImageRenderer`` on their
    /// native SwiftUI view. Returns nil if the kind has no rasterizable
    /// representation (e.g. html, which requires a live WKWebView).
    internal static func png(for artifact: LivingArtifact) async -> Data? {
        // Maps must snapshot via MapKit — ImageRenderer draws an empty box.
        if artifact.kind == "map",
           let spec = MapSpec.parse(artifact.content),
           let image = await MapExportRenderer.renderImage(spec: spec) {
            return pngData(from: image)
        }

        // Model blocks may contain map views — pre-render those.
        var diagramImages: [String: PlatformImage] = [:]
        if artifact.kind == "model",
           let spec = ModelSpec.parse(artifact.content) {
            for view in spec.views where view.kind == .map {
                if let mapJSON = ModelProjections.mapJSON(spec: spec, view: view),
                   let mapSpec = MapSpec.parse(mapJSON),
                   let image = await MapExportRenderer.renderImage(spec: mapSpec) {
                    diagramImages[mapJSON] = image
                }
            }
        }

        guard let view = exportContent(
            for: artifact,
            diagramImages: diagramImages.isEmpty ? nil : diagramImages
        ) else { return nil }

        let contentWidth: CGFloat = 1040
        let wrapped = VStack(alignment: .leading, spacing: 16) {
            exportHeader(for: artifact)
            view
        }
        .frame(width: contentWidth)
        .padding(24)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: wrapped)
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
        renderer.scale = 2.0

        #if os(macOS)
        guard let nsImage = renderer.nsImage else { return nil }
        return pngData(from: nsImage)
        #else
        guard let uiImage = renderer.uiImage else { return nil }
        return pngData(from: uiImage)
        #endif
    }

    // MARK: - Export content view

    /// Build the export-safe SwiftUI view for an artifact's kind. Returns nil
    /// for html (WKWebView — not rasterizable without a live view) and for
    /// maps (rasterized via MapExportRenderer, not SwiftUI).
    @ViewBuilder
    private static func exportContent(
        for artifact: LivingArtifact,
        diagramImages: [String: PlatformImage]? = nil
    ) -> AnyView? {
        switch artifact.kind {
        case "html":
            // WKWebView — not rasterizable offscreen.
            return nil
        case "map":
            // Maps are rendered as images via MapExportRenderer in the
            // png()/pdf() methods. For PDF, show the raw JSON as fallback.
            return AnyView(
                ExportCodeText(language: artifact.kind, code: artifact.content)
            )
        case "model":
            if let diagramImages {
                return AnyView(ExportModelArtifactView(artifact: artifact, diagramImages: diagramImages))
            }
            // PDF path without pre-rendered images — maps will show empty.
            return AnyView(
                ArtifactKindRenderer(
                    kind: artifact.kind,
                    content: artifact.content,
                    actionableArtifactID: nil,
                    suppressesPointerCapture: true
                )
            )
        default:
            // All other kinds: reuse ArtifactKindRenderer (non-interactive).
            // Charts, graphs, stats, tables, datasets, timelines, sankeys,
            // and markdown are ImageRenderer-safe (no scroll views, no
            // representables — the interactive variants are, but we pass
            // interactive: false via ArtifactKindRenderer for charts).
            return AnyView(
                ArtifactKindRenderer(
                    kind: artifact.kind,
                    content: artifact.content,
                    actionableArtifactID: nil,
                    suppressesPointerCapture: true
                )
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private static func exportHeader(for artifact: LivingArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(artifact.displayName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.primary)
            HStack(spacing: 10) {
                Text(artifact.kind.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.accent)
                if artifact.rev > 0 {
                    Text("r\(artifact.rev)")
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
                Text("· \(artifact.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            Rectangle()
                .fill(Theme.accent.opacity(0.4))
                .frame(height: 2)
                .padding(.top, 4)
        }
    }

    // MARK: - PNG helpers

    private static func pngData(from image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        return data
        #else
        return image.pngData()
        #endif
    }

    // MARK: - Filename

    internal static func filename(for artifact: LivingArtifact, format: Format) -> String {
        let slug = SessionExporter.slugify(artifact.displayName)
        return "\(slug).\(format.fileExtension)"
    }
}

// MARK: - Model artifact export view

/// Renders a model artifact with pre-rendered diagram images (maps),
/// mirroring SessionPDFExporter's ExportModelView.
private struct ExportModelArtifactView: View {
    internal let artifact: LivingArtifact
    internal let diagramImages: [String: PlatformImage]

    internal var body: some View {
        if let spec = ModelSpec.parse(artifact.content) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(spec.views) { view in
                    viewBlock(spec: spec, view: view)
                }
            }
        } else {
            ExportCodeText(language: "model", code: artifact.content)
        }
    }

    @ViewBuilder
    private func viewBlock(spec: ModelSpec, view: ModelSpec.View) -> some View {
        switch view.kind {
        case .markdown:
            MarkdownContentView(text: view.text, isStreaming: false)
                .equatable()
        case .map:
            if let mapJSON = ModelProjections.mapJSON(spec: spec, view: view),
               let image = diagramImages[mapJSON] {
                #if os(macOS)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                #else
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                #endif
            }
        case .table:
            ForEach(spec.sets(for: view), id: \.name) { set in
                let columns = view.columns.isEmpty ? derivedColumns(for: set) : view.columns
                VStack(alignment: .leading, spacing: 4) {
                    Text(set.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                    ExportTableView(
                        headers: columns,
                        rows: set.items.map { item in columns.map { item[$0] ?? "" } }
                    )
                }
            }
        case .graph:
            if let json = ModelProjections.graphJSON(spec: spec, view: view) {
                NetworkGraphView(json: json, isStreaming: false)
            }
        case .chart:
            if let json = ModelProjections.chartJSON(spec: spec, view: view) {
                NativeChartView(json: json, isStreaming: false, interactive: false)
            }
        case .stats:
            if let json = ModelProjections.statsJSON(spec: spec, view: view) {
                StatTilesView(json: json, isStreaming: false)
            }
        }
    }

    private func derivedColumns(for set: ModelSpec.EntitySet) -> [String] {
        var seen = Set<String>([set.key, "lat", "lon"])
        var derived = [set.key]
        for item in set.items {
            for field in item.keys.sorted() where seen.insert(field).inserted {
                derived.append(field)
            }
        }
        return derived
    }
}
