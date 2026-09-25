import SwiftUI

/// A service's architecture model, presented natively: one tab per contract
/// section (system map, extraction map, CI gates, inventory) rendered from the
/// decoded document, with the revision, the invariant tally and the last
/// `--check` in the header. Opened from a service node on the dataflow graph.
@MainActor
internal struct ArchitectureSurfaceView: View {
    private let request: ArchitectureRequest
    private let client: GatewayClient
    /// How Done closes the surface when it is hosted as a layer rather than a
    /// presentation (the environment's dismiss does nothing there).
    private let onDismiss: (() -> Void)?
    @StateObject private var model: ArchitectureSurfaceModel
    @State private var tab: ArchitectureSurfaceTab = .systemMap
    /// The service's code graph, presented over the surface from its header.
    @State private var presentedCodeGraph: CodeGraphRequest?
    @Environment(\.dismiss) private var dismiss

    internal init(request: ArchitectureRequest, client: GatewayClient, onDismiss: (() -> Void)? = nil) {
        self.request = request
        self.client = client
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: ArchitectureSurfaceModel(service: request.service, reader: client))
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            content
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #endif
        .background(Theme.background)
        .task(id: request.revision) { await model.load() }
        .task(id: model.revision) {
            // Switching stored revisions from the Revisions tab reloads the document.
            guard model.phase == .loaded || model.phase == .failed else { return }
            await model.load()
        }
        .sheet(item: $presentedCodeGraph) { codeGraph in
            CodeGraphSurfaceView(request: codeGraph, client: client)
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .help(model.document?.tooltip ?? request.service)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .help(model.document?.summary.detailLine ?? "")
                if let message = model.checkMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.isViewingOlderRevision, let document = model.document {
                revisionBadge(document)
            }
            if let check = model.document?.check {
                checkBadge(check)
            }
            if model.canRunCheck {
                Button(model.isChecking ? "Checking…" : "Run check") { Task { await model.runCheck() } }
                    .portalButton(prominent: false, size: .small)
                    .disabled(model.isChecking)
                    .help("Run the service's own --check in its checkout")
            }
            if let codeGraph = request.codeGraphRequest {
                Button("Code graph") { presentedCodeGraph = codeGraph }
                    .portalButton(prominent: false, size: .small)
                    .help("Open this service's code knowledge graph: modules, symbols and their relationships")
                    .accessibilityIdentifier("architecture.code-graph")
            }
            Button("Done") { close() }
                .portalButton(prominent: true, size: .small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var summary: String {
        guard let document = model.document else { return "Architecture model" }
        let invariants = "\(document.summary.invariantsHolding)/\(document.summary.invariantsTotal) invariants hold"
        let gates = document.summary.gates > 0 ? " · \(document.summary.gates) PR gates" : ""
        return "\(document.shortRevision) · \(document.service.origin) · \(document.summary.components) components · \(invariants)\(gates)"
    }

    /// The header's notice while an older stored revision is on screen.
    private func revisionBadge(_ document: ArchitectureModelDocument) -> some View {
        HStack(spacing: 8) {
            Text("Viewing revision \(document.shortRevision) · not latest")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.warning.opacity(0.14), in: Capsule())
                .help(document.storedAt.map { "Stored \($0)" } ?? "A stored snapshot, not the current model")
            Button("Back to latest") { Task { await model.load(revision: nil) } }
                .portalButton(prominent: false, size: .small)
                .accessibilityIdentifier("architecture.back-to-latest")
        }
    }

    private func checkBadge(_ check: ArchitectureCheckResult) -> some View {
        let color: Color = check.passed ? Theme.success : (check.ran ? Theme.warning : Theme.secondary)
        return Text(check.status.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .monospaced()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .help(check.detail)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            stateMessage(
                icon: "square.3.layers.3d",
                title: "Loading architecture model",
                detail: "Reading the service's compiled model and its invariants…",
                showsProgress: true
            )
        case .loaded:
            if let document = model.document {
                loadedContent(document)
            }
        case .failed:
            VStack(spacing: 14) {
                stateMessage(
                    icon: "exclamationmark.triangle",
                    title: "Architecture model unavailable",
                    detail: model.errorMessage ?? "The gateway could not read this service's model."
                )
                Button("Try Again") { Task { await model.load() } }
                    .portalButton(prominent: false, size: .small)
            }
        }
    }

    /// The tab strip over the section the tab renders. Only tabs whose section
    /// the document carries are offered; a selection that vanished with a
    /// reload falls back to the first available tab. A document with no
    /// renderable section is non-conforming and says so instead of a tab strip.
    @ViewBuilder
    private func loadedContent(_ document: ArchitectureModelDocument) -> some View {
        let tabs = ArchitectureSurfaceTab.available(for: document)
        if let current = tabs.contains(tab) ? tab : tabs.first {
            tabbedContent(current, tabs: tabs, document: document)
        } else {
            stateMessage(
                icon: "exclamationmark.triangle",
                title: "Non-conforming architecture model",
                detail: "The document carries none of the sections the hermes.architecture contract requires"
                    + " (missing \(document.missingRequiredSections.map(\.rawValue).joined(separator: ", ")))."
            )
        }
    }

    private func tabbedContent(_ current: ArchitectureSurfaceTab, tabs: [ArchitectureSurfaceTab], document: ArchitectureModelDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                ThemedSegmentedControl(selection: $tab, options: tabs, label: { $0.title }, icon: { $0.icon })
                Spacer()
                if !document.missingRequiredSections.isEmpty {
                    Text("Non-conforming: missing \(document.missingRequiredSections.map(\.rawValue).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .help("The hermes.architecture contract requires these sections; the gateway served the document unvalidated.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().background(Theme.border)
            sectionContent(current, document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func sectionContent(_ tab: ArchitectureSurfaceTab, document: ArchitectureModelDocument) -> some View {
        switch tab {
        case .systemMap:
            ArchitectureSystemMapSectionView(document: document)
        case .extraction:
            ArchitectureExtractionSectionView(document: document)
        case .gates:
            ArchitectureGatesSectionView(document: document)
        case .inventory:
            ArchitectureInventorySectionView(document: document)
        case .logs:
            ArchitectureLogsSectionView(service: request.service, sinks: document.service.logs, reader: client)
        case .revisions:
            ArchitectureRevisionsSectionView(service: request.service, reader: client, surface: model)
        }
    }

    private func stateMessage(
        icon: String,
        title: String,
        detail: String,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.secondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
