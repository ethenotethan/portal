import SwiftUI

/// The one markdown reader for the wiki: rendered content with clickable
/// wikilinks, frontmatter chips, backlinks, and back/forward history — all
/// driven by the shared selection plane on WikiGraphViewModel. Hosted by the
/// file browser (inline), the graph modes (side panel / sheet), and the
/// timeline.
struct WikiReaderPane: View {
    @ObservedObject var viewModel: WikiGraphViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    /// Compact files-mode: shows a "Files" back button that closes the page.
    var showsCompactBack = false
    /// Sheet/panel hosting: shows a close affordance.
    var onClose: (() -> Void)?
    /// Hidden when the reader already sits next to the 2D graph.
    var showsShowInGraph = true

    var body: some View {
        Group {
            if let path = viewModel.selectedPath {
                pageView(path: path)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 34))
                .foregroundStyle(Theme.tertiary)
            Text("Select a page")
                .font(.callout)
                .foregroundStyle(Theme.tertiary)
        }
    }

    @ViewBuilder
    private func pageView(path: String) -> some View {
        let page = viewModel.graph.pages.first { $0.path == path }
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(path: path, page: page)
            Divider()
            // The docked pane drives the shared selection plane: links and
            // backlinks navigate the one current page.
            WikiPageReaderBody(
                viewModel: viewModel,
                path: path,
                onNavigate: { viewModel.navigate(to: $0) }
            )
        }
    }

    private func pageHeader(path: String, page: WikiPage?) -> some View {
        HStack(spacing: 10) {
            if showsCompactBack {
                Button {
                    viewModel.closePage()
                } label: {
                    Label("Files", systemImage: "chevron.backward")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            Button {
                viewModel.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canGoBack)

            Button {
                viewModel.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canGoForward)

            VStack(alignment: .leading, spacing: 2) {
                Text(page?.title ?? displayName(for: path))
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if showsShowInGraph, page != nil {
                Button {
                    viewModel.showCurrentPageInGraph()
                } label: {
                    Label("Show in Graph", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Select and center this page's node in the 2D graph")
            }

            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func displayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
