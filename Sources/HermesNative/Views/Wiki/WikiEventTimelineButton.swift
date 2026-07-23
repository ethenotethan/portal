import SwiftUI

/// Toolbar entry point for the Compendium event timeline. Self-contained
/// (owns its presentation state and sheet) so WikiGraphView only inserts one
/// line per toolbar — easy to re-home when the wiki toolbar is restructured.
///
/// Renders nothing unless the loaded source serves the timeline endpoints
/// (`WikiEventTimelineProviding`) — i.e. Centaur wikis only; the Hermes
/// gateway does not conform.
struct WikiEventTimelineButton: View {
    /// The wiki source the surrounding view is browsing.
    let source: (any WikiSource)?
    /// Shared selection plane, passed through so directive target-page chips
    /// can jump into the wiki.
    @ObservedObject var viewModel: WikiGraphViewModel

    @State private var showTimeline = false

    var body: some View {
        if let provider = source as? (any WikiEventTimelineProviding) {
            Button {
                showTimeline = true
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Events — Compendium ingestion timeline")
            .sheet(isPresented: $showTimeline) {
                WikiEventTimelineView(
                    provider: provider,
                    viewModel: viewModel,
                    onClose: { showTimeline = false }
                )
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 560)
                #endif
            }
        }
    }
}
