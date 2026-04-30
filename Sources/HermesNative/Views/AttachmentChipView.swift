import SwiftUI

/// Tappable chip for a file attachment extracted from a MEDIA: tag.
/// Shows icon + filename, opens FilePreviewView on tap.
struct AttachmentChipView: View {
    let attachment: FileAttachment
    @State private var isPreviewVisible = false

    var body: some View {
        Button {
            isPreviewVisible = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: attachment.category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    Text(attachment.fileExtension.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPreviewVisible) {
            FilePreviewView(attachment: attachment)
        }
    }
}

// MARK: - File Preview (Sheet)

/// Full-sheet preview for file attachments.
/// Uses WKWebView for HTML and PDF (both render natively),
/// Quick Look for images, and NSWorkspace.open for everything else.
struct FilePreviewView: View {
    let attachment: FileAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(attachment.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)

                Button {
                    openInDefaultApp()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in default app")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface)

            Divider()

            // Content
            Group {
                switch attachment.category {
                case .html, .pdf:
                    WebViewSheet(filePath: attachment.path)
                case .image:
                    ImagePreview(filePath: attachment.path)
                default:
                    FallbackPreview(attachment: attachment)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Theme.background)
    }

    private func openInDefaultApp() {
        let url = URL(fileURLWithPath: attachment.path)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - WKWebView Sheet (HTML + PDF)

import WebKit

struct WebViewSheet: NSViewRepresentable {
    let filePath: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let url = URL(fileURLWithPath: filePath)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

// MARK: - Image Preview

struct ImagePreview: View {
    let filePath: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let nsImage = NSImage(contentsOfFile: filePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            } else {
                FallbackLabel(text: "Could not load image")
            }
        }
    }
}

// MARK: - Fallback (opens in default app)

struct FallbackPreview: View {
    let attachment: FileAttachment

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: attachment.category.icon)
                .font(.system(size: 48))
                .foregroundStyle(Theme.tertiary)

            Text(attachment.fileName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primary)

            Text("Preview not available for .\(attachment.fileExtension) files")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)

            Button("Open in Default App") {
                NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path))
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FallbackLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
