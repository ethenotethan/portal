import SwiftUI
import WebKit

struct ActivityInboxView: View {
    @ObservedObject var viewModel: ActivityInboxViewModel
    var onOpenSession: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            List(selection: Binding(
                get: { viewModel.selectedItem?.id },
                set: { id in viewModel.selectedItem = viewModel.items.first(where: { $0.id == id }) }
            )) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
                ForEach(viewModel.items) { item in
                    NavigationLink(value: item) {
                        ActivityRowView(item: item)
                    }
                    .tag(item.id)
                    .contextMenu {
                        Button(item.isRead ? "Mark Unread" : "Mark Read") {
                            Task { await viewModel.markRead(item, read: !item.isRead) }
                        }
                        Button("Dismiss", role: .destructive) {
                            Task { await viewModel.dismiss(item) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("activityRefreshButton")
                }
            }
            .navigationDestination(for: ActivityItem.self) { item in
                ActivityDetailView(item: item, viewModel: viewModel, onOpenSession: onOpenSession)
            }
            .task { await viewModel.refresh() }
        }
        .background(Theme.background)
    }
}

private struct ActivityRowView: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.severity.icon)
                .foregroundStyle(color(for: item.severity))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .foregroundStyle(Theme.primary)
                        .font(.headline)
                        .lineLimit(1)
                    if !item.isRead {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(item.unreadBadgeAccessibilityLabel)
                    }
                    Spacer()
                    Text(item.relativeTimestamp)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ActivityPill(text: item.kind)
                    if let sessionID = item.sessionID {
                        ActivityPill(text: String(sessionID.prefix(8)))
                    }
                    ForEach(item.artifacts.prefix(3)) { artifact in
                        ActivityPill(text: artifact.typeLabel)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.background)
    }

    private func color(for severity: ActivitySeverity) -> Color {
        switch severity {
        case .info: Theme.accent
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct ActivityPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.surface)
            .clipShape(Capsule())
    }
}

private struct ActivityDetailView: View {
    let item: ActivityItem
    @ObservedObject var viewModel: ActivityInboxViewModel
    var onOpenSession: ((String) -> Void)?
    @State private var selectedArtifact: ActivityArtifactContent?
    @State private var artifactError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.primary)
                    Text(item.relativeTimestamp)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    ActivityPill(text: item.kind)
                    ActivityPill(text: item.source)
                    ActivityPill(text: item.severity.rawValue)
                }

                if let sessionID = item.sessionID {
                    Button {
                        Task { await viewModel.markRead(item) }
                        onOpenSession?(sessionID)
                    } label: {
                        Label("Open Session", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !item.artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Artifacts")
                            .font(.headline)
                            .foregroundStyle(Theme.primary)
                        ForEach(item.artifacts) { artifact in
                            Button {
                                Task { await loadArtifact(artifact) }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.richtext")
                                    VStack(alignment: .leading) {
                                        Text(artifact.name).foregroundStyle(Theme.primary)
                                        Text("\(artifact.typeLabel) · \(artifact.size) bytes")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(Theme.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                if !item.externalRefs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Links")
                            .font(.headline)
                            .foregroundStyle(Theme.primary)
                        ForEach(item.externalRefs) { ref in
                            if let url = URL(string: ref.url) {
                                Link(ref.label, destination: url)
                            }
                        }
                    }
                }

                if let artifactError {
                    Text(artifactError)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("Activity Detail")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(item.isRead ? "Mark Unread" : "Mark Read") {
                    Task { await viewModel.markRead(item, read: !item.isRead) }
                }
            }
        }
        .sheet(item: $selectedArtifact) { artifact in
            ActivityArtifactView(artifact: artifact)
        }
        .task {
            if !item.isRead { await viewModel.markRead(item) }
        }
    }

    private func loadArtifact(_ artifact: ActivityArtifact) async {
        artifactError = nil
        do {
            selectedArtifact = try await viewModel.artifactContent(id: artifact.id)
        } catch {
            artifactError = error.localizedDescription
        }
    }
}

private struct ActivityArtifactView: View {
    let artifact: ActivityArtifactContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(artifact.name)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            .background(Theme.surface)

            Group {
                if artifact.mimeType == "text/html" || artifact.name.lowercased().hasSuffix(".html") {
                    HTMLArtifactWebView(html: artifact.content ?? "")
                } else if artifact.mimeType == "text/markdown" || artifact.name.lowercased().hasSuffix(".md") {
                    ScrollView { MarkdownContentView(text: artifact.content ?? "") .padding() }
                } else if artifact.mimeType.hasPrefix("text/") || artifact.name.lowercased().hasSuffix(".log") {
                    ScrollView {
                        Text(artifact.content ?? "")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc")
                            .font(.largeTitle)
                        Text("Preview unavailable for \(artifact.mimeType)")
                        Text(artifact.contentBase64 == nil ? "No downloadable payload returned." : "Binary payload received.")
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(Theme.primary)
                }
            }
        }
        .background(Theme.background)
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct HTMLArtifactWebView: View {
    let html: String

    var body: some View {
        #if os(macOS)
        HTMLArtifactNSView(html: html)
        #else
        HTMLArtifactUIView(html: html)
        #endif
    }
}

#if os(macOS)
private struct HTMLArtifactNSView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) { webView.loadHTMLString(html, baseURL: nil) }
}
#else
private struct HTMLArtifactUIView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) { webView.loadHTMLString(html, baseURL: nil) }
}
#endif

private func makeWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: config)
    #if os(macOS)
    webView.setValue(false, forKey: "drawsBackground")
    #else
    webView.isOpaque = false
    webView.backgroundColor = .clear
    #endif
    return webView
}
