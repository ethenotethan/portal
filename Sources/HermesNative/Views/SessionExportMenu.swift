import SwiftUI
import UniformTypeIdentifiers

/// Entry points for exporting the open session as Markdown / PDF.
/// Kept out of ChatView so the toolbar diff stays a one-line insertion.
///
/// - macOS: a small borderless "Export" menu in the chat header row;
///   Markdown/PDF are written via NSSavePanel. PDF keeps the existing rich
///   SessionPDFExporter (native charts/diagrams); Markdown is the new
///   LLM-friendly transcript from SessionExporter.
/// - iOS: menu items for the chat overflow menu; both write a temp file and
///   present the system share sheet.
@MainActor
enum SessionExportSupport {

    /// Assemble the markdown document for the currently open session.
    /// Usage is fetched best-effort from the gateway and skipped on failure.
    static func markdown(
        chatViewModel: ChatViewModel,
        gatewayClientWrapper: GatewayClientWrapper,
        settings: SettingsViewModel,
        assistantName: String
    ) async -> String {
        let messages = chatViewModel.messages.filter { !$0.isStreaming }
        var usage: SessionUsage?
        if let sessionID = chatViewModel.currentSessionID {
            usage = (try? await gatewayClientWrapper.client.sessionUsage(sessionID: sessionID))
        }
        let metadata = SessionExporter.Metadata(
            title: chatViewModel.sessionTitle,
            sessionID: chatViewModel.currentSessionID,
            gatewayName: settings.focusedGateway?.displayName,
            model: chatViewModel.currentModel.isEmpty ? nil : chatViewModel.currentModel,
            usage: usage,
            assistantName: assistantName
        )
        return SessionExporter.markdown(messages: messages, metadata: metadata)
    }

    static var markdownType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }
}

#if os(macOS)
/// "Export" menu for the macOS chat header: Export as Markdown… / PDF….
struct SessionExportMenu: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var settings: SettingsViewModel

    let assistantName: String

    @State private var isExporting = false

    private var canExport: Bool {
        !isExporting && !chatViewModel.messages.isEmpty && !chatViewModel.isStreaming
    }

    var body: some View {
        Menu {
            Button {
                exportMarkdown()
            } label: {
                Label("Export as Markdown…", systemImage: "doc.plaintext")
            }
            Button {
                exportPDF()
            } label: {
                Label("Export as PDF…", systemImage: "doc.richtext")
            }
        } label: {
            if isExporting {
                HermesProgressView()
                    .scaleEffect(0.5)
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Theme.secondary)
        .disabled(!canExport)
        .help("Export this session — Markdown for another agent's context, PDF for sharing")
    }

    private func exportMarkdown() {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            let document = await SessionExportSupport.markdown(
                chatViewModel: chatViewModel,
                gatewayClientWrapper: gatewayClientWrapper,
                settings: settings,
                assistantName: assistantName
            )
            Self.savePanel(
                data: Data(document.utf8),
                defaultName: SessionExporter.filename(title: chatViewModel.sessionTitle, fileExtension: "md"),
                contentType: SessionExportSupport.markdownType
            )
        }
    }

    private func exportPDF() {
        let messages = chatViewModel.messages.filter { !$0.isStreaming }
        guard !messages.isEmpty else { return }
        let title = chatViewModel.sessionTitle
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            // Rich native render (charts, diagrams, tables) — falls back to
            // the markdown-derived CoreText PDF if the view render fails.
            var data = await SessionPDFExporter.export(
                messages: messages,
                title: title,
                assistantName: assistantName
            )
            if data == nil {
                let document = await SessionExportSupport.markdown(
                    chatViewModel: chatViewModel,
                    gatewayClientWrapper: gatewayClientWrapper,
                    settings: settings,
                    assistantName: assistantName
                )
                data = SessionExporter.pdf(markdown: document, title: title)
            }
            guard let data else { return }
            Self.savePanel(
                data: data,
                defaultName: SessionExporter.filename(title: title, fileExtension: "pdf"),
                contentType: .pdf
            )
        }
    }

    @MainActor
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

/// Non-open-session export: reads persisted history from ChatHistoryStore,
/// so any session with local history can be exported from the sidebar
/// context menu without opening it.
@MainActor
enum SessionListExport {

    static func canExport(sessionID: String) -> Bool {
        ChatHistoryStore.shared.hasLocalMessages(forSession: sessionID)
    }

    static func exportMarkdown(session: Session, title: String, gatewayName: String?) {
        guard let messages = ChatHistoryStore.shared.loadMessages(forSession: session.id) else { return }
        let metadata = SessionExporter.Metadata(
            title: title,
            sessionID: session.id,
            gatewayName: gatewayName,
            source: session.source,
            startedAt: session.startedAt,
            lastActive: session.lastActive,
            assistantName: "Assistant"
        )
        let document = SessionExporter.markdown(messages: messages, metadata: metadata)
        SessionExportMenu.savePanel(
            data: Data(document.utf8),
            defaultName: SessionExporter.filename(title: title, fileExtension: "md"),
            contentType: SessionExportSupport.markdownType
        )
    }
}
#endif

#if os(iOS)
/// Export items for the iOS chat overflow menu (ellipsis.circle). Each writes
/// a temp file and presents the system share sheet.
struct SessionExportMenuItems: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var settings: SettingsViewModel

    let assistantName: String

    private var canExport: Bool {
        !chatViewModel.messages.isEmpty && !chatViewModel.isStreaming
    }

    var body: some View {
        Button {
            Task { await share(fileExtension: "md") }
        } label: {
            Label("Export as Markdown", systemImage: "doc.plaintext")
        }
        .disabled(!canExport)

        Button {
            Task { await share(fileExtension: "pdf") }
        } label: {
            Label("Export as PDF", systemImage: "doc.richtext")
        }
        .disabled(!canExport)
    }

    @MainActor
    private func share(fileExtension: String) async {
        let title = chatViewModel.sessionTitle
        let document = await SessionExportSupport.markdown(
            chatViewModel: chatViewModel,
            gatewayClientWrapper: gatewayClientWrapper,
            settings: settings,
            assistantName: assistantName
        )
        let data: Data?
        if fileExtension == "pdf" {
            data = SessionExporter.pdf(markdown: document, title: title)
        } else {
            data = Data(document.utf8)
        }
        guard let data else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(SessionExporter.filename(title: title, fileExtension: fileExtension))
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
        // iPad requires a popover anchor.
        activity.popoverPresentationController?.sourceView = presenter.view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1
        )
        presenter.present(activity, animated: true)
    }
}
#endif
