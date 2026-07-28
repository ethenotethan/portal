import SwiftUI
import WebKit

/// Tappable chip for a file attachment extracted from a MEDIA: tag.
/// Shows icon + filename, and handles download state for remote files.
/// Opens FilePreviewView on tap when ready.
struct AttachmentChipView: View {
    let attachment: FileAttachment
    @State private var isPreviewVisible = false

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 8) {
                // Status indicator (left side icon)
                statusIcon
                    .frame(width: 28, height: 28)
                    .background(statusBackgroundColor, in: RoundedRectangle(cornerRadius: 6))

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

                // Right-side indicator
                rightIndicator
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
        #if os(iOS)
        // macOS opens a full-window overlay directly from handleTap()/openPreview().
        .fullScreenCover(isPresented: $isPreviewVisible) {
            FilePreviewView(attachment: attachment)
        }
        #endif
        .onAppear {
            // Trigger pre-fetch for remote attachments on appear
            if attachment.isRemote, case .notStarted = attachment.downloadState {
                Task {
                    await prefetchRemoteAttachment()
                }
            }
        }
    }

    // MARK: - State-dependent views

    @ViewBuilder
    private var statusIcon: some View {
        switch attachment.downloadState {
        case .notStarted:
            if attachment.isRemote {
                PortalProgressView()
                    .scaleEffect(0.6)
            } else {
                Image(systemName: attachment.category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
            }
        case .downloading:
            PortalProgressView()
                .scaleEffect(0.6)
        case .ready:
            Image(systemName: attachment.category.icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.warning)
        }
    }

    private var statusBackgroundColor: Color {
        switch attachment.downloadState {
        case .notStarted where attachment.isRemote:
            Theme.accent.opacity(0.12)
        case .downloading:
            Theme.accent.opacity(0.12)
        case .ready:
            Theme.success.opacity(0.12)
        case .failed:
            Theme.warning.opacity(0.12)
        default:
            Theme.accent.opacity(0.12)
        }
    }

    @ViewBuilder
    private var rightIndicator: some View {
        switch attachment.downloadState {
        case .notStarted where attachment.isRemote:
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(Theme.accent)
        case .downloading:
            if let progress = attachment.downloadProgress {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "arrow.down.circle")
            }
        case .ready:
            Image(systemName: "arrow.up.right.square")
        case .failed:
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(Theme.warning)
        default:
            Image(systemName: "arrow.up.right.square")
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch attachment.downloadState {
        case .notStarted where attachment.isRemote:
            // Start download
            Task {
                await prefetchRemoteAttachment()
            }
        case .downloading:
            // No-op — already downloading
            break
        case .ready:
            openPreview()
        case .failed:
            // Retry
            Task {
                await prefetchRemoteAttachment()
            }
        default:
            openPreview()
        }
    }

    private func openPreview() {
        #if os(macOS)
        // Full-window SwiftUI overlay via the shared presenter (mounted at the
        // app root). Injecting an AppKit subview rendered nothing.
        HTMLPreviewPresenter.shared.showAttachment(attachment)
        #else
        isPreviewVisible = true
        #endif
    }

    private func prefetchRemoteAttachment() async {
        // Access the download manager via the attachment's environment
        // The actual download is triggered by ChatViewModel observing the attachment
        // and calling FileDownloadManager. For standalone usage, this is a no-op.
        // The onAppear + handleTap serve as triggers; the actual download logic
        // is driven by ChatViewModel integration.
    }
}

// MARK: - DownloadProgress Helper

extension FileAttachment.DownloadState {
    var progressValue: Double? {
        if case .downloading(let p) = self { return p }
        if case .ready = self { return 1.0 }
        return nil
    }
}

extension FileAttachment {
    var downloadProgress: Double? {
        downloadState.progressValue
    }
}

// MARK: - File Preview (Sheet)

/// Full-sheet preview for file attachments.
/// Supports both local files and remote (downloaded) data.
struct FilePreviewView: View {
    let attachment: FileAttachment
    /// When hosted as a full-window overlay (macOS), there's no sheet to
    /// dismiss — the host passes a close action.
    var onClose: (() -> Void)?
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
                    if let onClose { onClose() } else { dismiss() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)

                if case .local = attachment.source {
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface)

            Divider()

            // Content
            Group {
                switch attachment.category {
                case .html, .pdf:
                    if case .ready(let data) = attachment.downloadState {
                        FileWebView(data: data, mimeType: attachment.mimeType ?? "text/html")
                    } else if case .local(let path) = attachment.source {
                        FileWebView(filePath: path)
                    } else {
                        downloadStateView
                    }
                case .image:
                    if case .ready(let data) = attachment.downloadState {
                        ImagePreview(data: data)
                    } else if case .local(let path) = attachment.source {
                        ImagePreview(filePath: path)
                    } else {
                        downloadStateView
                    }
                default:
                    // Show downloaded/text content inline when we can decode it
                    // as text (json, csv, txt, code, logs…); otherwise fall back
                    // to a filename card with "open in default app".
                    if case .ready(let data) = attachment.downloadState {
                        if let text = Self.decodeText(data) {
                            TextFilePreview(text: text)
                        } else {
                            FallbackPreview(attachment: attachment)
                        }
                    } else if case .local(let path) = attachment.source {
                        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let text = Self.decodeText(data) {
                            TextFilePreview(text: text)
                        } else {
                            FallbackPreview(path: path, fileName: attachment.fileName, fileExtension: attachment.fileExtension)
                        }
                    } else {
                        downloadStateView
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Theme.background)
    }

    /// Decode raw bytes as human-readable text, or nil if it looks binary.
    /// Mirrors the send-side plain-text detection.
    static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // A NUL byte in the first chunk is a strong binary signal.
        if data.prefix(8000).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    @ViewBuilder
    private var downloadStateView: some View {
        VStack(spacing: 16) {
            if case .downloading(let progress) = attachment.downloadState {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                    .tint(Theme.accent)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            } else if case .failed(let error) = attachment.downloadState {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.warning)
                Text("Download failed")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primary)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                PortalProgressView()
                    .scaleEffect(0.8)
                Text("Preparing file…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openInDefaultApp() {
        guard case .local(let path) = attachment.source else { return }
        let url = URL(fileURLWithPath: path)
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - WKWebView (HTML + PDF)

struct FileWebView: View {
    let filePath: String?
    let data: Data?
    let mimeType: String

    init(filePath: String) {
        self.filePath = filePath
        self.data = nil
        self.mimeType = "text/html"
    }

    init(data: Data, mimeType: String) {
        self.filePath = nil
        self.data = data
        self.mimeType = mimeType
    }

    var body: some View {
        #if os(macOS)
        FileWebViewNSView(filePath: filePath, data: data, mimeType: mimeType)
        #else
        FileWebViewUIView(filePath: filePath, data: data, mimeType: mimeType)
        #endif
    }
}

#if os(macOS)
struct FileWebViewNSView: NSViewRepresentable {
    let filePath: String?
    let data: Data?
    let mimeType: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let data = data {
            webView.load(
                data,
                mimeType: mimeType,
                characterEncodingName: "UTF-8",
                baseURL: URL(string: "about:blank")!
            )
        } else if let filePath = filePath {
            let url = URL(fileURLWithPath: filePath)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}
#else
struct FileWebViewUIView: UIViewRepresentable {
    let filePath: String?
    let data: Data?
    let mimeType: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let data = data {
            webView.load(
                data,
                mimeType: mimeType,
                characterEncodingName: "UTF-8",
                baseURL: URL(string: "about:blank")!
            )
        } else if let filePath = filePath {
            let url = URL(fileURLWithPath: filePath)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}
#endif

// MARK: - Image Preview

struct ImagePreview: View {
    let filePath: String?
    let data: Data?

    init(filePath: String) {
        self.filePath = filePath
        self.data = nil
    }

    init(data: Data) {
        self.filePath = nil
        self.data = data
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let data = data {
                #if os(macOS)
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    FallbackLabel(text: "Could not decode image data")
                }
                #else
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    FallbackLabel(text: "Could not decode image data")
                }
                #endif
            } else if let filePath = filePath {
                #if os(macOS)
                if let nsImage = NSImage(contentsOfFile: filePath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    FallbackLabel(text: "Could not load image")
                }
                #else
                if let uiImage = UIImage(contentsOfFile: filePath) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    FallbackLabel(text: "Could not load image")
                }
                #endif
            } else {
                FallbackLabel(text: "No image data available")
            }
        }
    }
}

// MARK: - Fallback (opens in default app)

struct FallbackPreview: View {
    let path: String?
    let fileName: String
    let fileExtension: String

    init(path: String, fileName: String, fileExtension: String) {
        self.path = path
        self.fileName = fileName
        self.fileExtension = fileExtension
    }

    init(attachment: FileAttachment) {
        if case .local(let p) = attachment.source {
            self.path = p
        } else {
            self.path = nil
        }
        self.fileName = attachment.fileName
        self.fileExtension = attachment.fileExtension
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc")
                .font(.system(size: 48))
                .foregroundStyle(Theme.tertiary)

            Text(fileName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primary)

            Text("Preview not available for .\(fileExtension) files")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)

            if let path = path {
                Button("Open in Default App") {
                    let url = URL(fileURLWithPath: path)
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Scrollable monospaced preview for downloaded text-like files (json, csv,
/// logs, source code, etc.) that have no dedicated viewer.
struct TextFilePreview: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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
