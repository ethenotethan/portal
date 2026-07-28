import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Export/share menu for a single artifact from the detail pane header.
///
/// Offers Markdown, PDF, and PNG export via ``ArtifactExporter``:
/// - **macOS:** menu button → NSSavePanel for each format.
/// - **iOS:** menu button → system share sheet (temp file + UIActivityViewController).
internal struct ArtifactExportMenu: View {
    internal let artifact: LivingArtifact

    @State private var isExporting = false

    internal var body: some View {
        Menu {
            ForEach(ArtifactExporter.Format.allCases, id: \.self) { format in
                Button {
                    export(format)
                } label: {
                    Label(format.rawValue, systemImage: format.icon)
                }
            }
        } label: {
            if isExporting {
                PortalProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isExporting)
        .help("Export this artifact — Markdown, PDF, or PNG")
        .id(artifact.id)
    }

    private func export(_ format: ArtifactExporter.Format) {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            let data: Data?
            switch format {
            case .markdown:
                let doc = ArtifactExporter.markdown(for: artifact)
                data = Data(doc.utf8)
            case .pdf:
                data = await ArtifactExporter.pdf(for: artifact)
            case .png:
                data = await ArtifactExporter.png(for: artifact)
            }
            guard let data else { return }

            #if os(macOS)
            Self.savePanel(
                data: data,
                defaultName: ArtifactExporter.filename(for: artifact, format: format),
                contentType: format.utType
            )
            #else
            Self.share(
                data: data,
                fileExtension: format.fileExtension,
                filename: ArtifactExporter.filename(for: artifact, format: format)
            )
            #endif
        }
    }
}

// MARK: - ArtifactExporter.Format UTType

extension ArtifactExporter.Format {
    internal var utType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .png: return .png
        }
    }
}

// MARK: - Platform save/share

#if os(macOS)
@MainActor
private enum ArtifactExportMenuMac {
    static func savePanel(data: Data, defaultName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not save export"
            alert.runModal()
        }
    }
}

extension ArtifactExportMenu {
    internal static func savePanel(data: Data, defaultName: String, contentType: UTType) {
        ArtifactExportMenuMac.savePanel(data: data, defaultName: defaultName, contentType: contentType)
    }
}
#endif

#if os(iOS)
extension ArtifactExportMenu {
    @MainActor
    internal static func share(data: Data, fileExtension: String, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController
        else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = presenter.view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1
        )
        presenter.present(activity, animated: true)
    }
}
#endif
