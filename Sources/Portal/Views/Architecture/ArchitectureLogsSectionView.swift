import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Logs tab: the declared sinks of a local service, the tail of the chosen
/// one, a follow switch that streams new lines as they land, and a filter over
/// what is buffered. Only sinks the manifest declares are ever read.
@MainActor
internal struct ArchitectureLogsSectionView: View {
    @StateObject private var model: ArchitectureLogsModel
    @State private var autoScroll = true

    internal init(service: String, sinks: [ArchitectureLogSink], reader: any ArchitectureReading) {
        _model = StateObject(wrappedValue: ArchitectureLogsModel(service: service, sinks: sinks, reader: reader))
    }

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Theme.border)
            if let sink = model.selectedSink {
                sinkCaption(sink)
                Divider().background(Theme.border)
            }
            content
        }
        .background(Theme.background)
        .task { await model.load() }
        .onDisappear { Task { await model.teardown() } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Sink", selection: Binding(
                get: { model.selectedSinkID ?? "" },
                set: { id in Task { await model.select(sinkID: id) } }
            )) {
                ForEach(model.sinks) { sink in
                    Text("\(sink.displayLabel) · \(sink.kindLabel)").tag(sink.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .help("Which declared log sink to read")
            TextField("Filter lines…", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Spacer()
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Toggle("Follow", isOn: Binding(
                get: { model.isFollowing },
                set: { enabled in Task { await model.setFollowing(enabled) } }
            ))
            .toggleStyle(.switch)
            .help("Stream new lines as the service writes them")
            Button("Refresh") { Task { await model.fetchMore() } }
                .portalButton(prominent: false, size: .small)
                .disabled(model.isLoading)
                .help("Fetch what was appended since the last read")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sinkCaption(_ sink: ArchitectureLogSink) -> some View {
        HStack(spacing: 10) {
            Text(sink.path)
                .font(.system(size: 11, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(sink.sizeLabel)
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(sink.exists ? Theme.tertiary : Theme.warning)
            if !sink.modifiedAt.isEmpty {
                Text("modified \(sink.modifiedAt)")
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text("\(model.filteredLines.count) of \(model.lines.count) lines\(model.truncated ? " · more on disk" : "")")
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.errorMessage {
            emptyState(icon: "exclamationmark.triangle", title: "Log unavailable", detail: message)
        } else if model.sinks.isEmpty {
            emptyState(
                icon: "text.alignleft",
                title: "No log sink declared",
                detail: "Add a `logs` sink to this service's manifest; the gateway reads only declared sinks."
            )
        } else if model.lines.isEmpty, !model.isLoading {
            emptyState(icon: "text.alignleft", title: "Nothing logged yet", detail: "The sink exists but holds no complete line.")
        } else {
            logList
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.filteredLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 1)
                            .background(index.isMultiple(of: 2) ? Color.clear : Theme.surface.opacity(0.4))
                            .contextMenu {
                                Button("Copy line") { copyToClipboard(line) }
                            }
                            .id(index)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.lines.count) { _, _ in
                guard autoScroll, model.isFollowing, let last = model.filteredLines.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
