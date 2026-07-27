#if os(macOS)
import SwiftUI

/// The wiki reader on macOS: a right-docked panel over the always-alive graph,
/// replacing the old free-form floating cards. Three read-only focus levels,
/// all sharing ONE selection plane (no per-card history):
///
/// - **Peek** (default): the panel docks on the right, the graph stays
///   interactive to its left, and a draggable leading divider widens/narrows it.
/// - **Fullscreen**: one toggle fills the reader over the whole graph; toggle
///   again (or Esc) to return to Peek. This IS "Focus" — a boolean, not a mode.
/// - **Compare**: pinning the current page keeps it on-screen; the panel then
///   tiles the active page plus every pinned page in an auto-grid.
///
/// The panel drives the shared selection plane directly (links/backlinks
/// navigate the one current page), so the graph node highlight always follows
/// what's on top — the same wiring the iOS sheet uses.
internal struct WikiDockedReader: View {
    @ObservedObject internal var viewModel: WikiGraphViewModel
    /// Full wiki surface width, used to clamp the divider drag. The panel never
    /// takes more than ~70% of it.
    internal let surfaceWidth: CGFloat

    @State private var dragStartWidth: CGFloat?

    private static let dividerWidth: CGFloat = 9
    private static let gripHeight: CGFloat = 30

    internal var body: some View {
        HStack(spacing: 0) {
            // The divider is part of the panel (leading edge) so the hosting
            // layout only has to place ONE view. Hidden in fullscreen — there's
            // no graph beside it to resize against.
            if !viewModel.readerFullscreen {
                divider
            }
            panel
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .leading) {
            // A hairline seam against the graph in Peek; the fullscreen panel
            // owns the whole surface and needs none.
            if !viewModel.readerFullscreen {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
        }
    }

    // MARK: - Toolbar (shared history + focus controls)

    private var toolbar: some View {
        let path = viewModel.selectedPath
        let page = path.flatMap { p in viewModel.graph.pages.first { $0.path == p } }
        return HStack(spacing: 10) {
            Button { viewModel.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canGoBack)
            .help("Back")

            Button { viewModel.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canGoForward)
            .help("Forward")

            VStack(alignment: .leading, spacing: 1) {
                Text(page?.title ?? displayName(for: path))
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            focusControls(page: page)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder
    private func focusControls(page: WikiPage?) -> some View {
        // Pin the current page to hold it beside the next one (Compare).
        if viewModel.selectedPath != nil {
            Button { viewModel.pinCurrentPage() } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(currentPageIsPinned)
            .help("Compare — keep this page open beside the next")
        }

        if page != nil {
            Button { viewModel.showCurrentPageInGraph() } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.borderless)
            .help("Center this page's node in the graph")
        }

        Button { viewModel.toggleReaderFullscreen() } label: {
            Image(systemName: viewModel.readerFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .help(viewModel.readerFullscreen ? "Exit fullscreen" : "Fill over the graph")

        Button { viewModel.deactivateSelection() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.borderless)
        .help("Close")
    }

    private var currentPageIsPinned: Bool {
        guard let path = viewModel.selectedPath else { return false }
        return viewModel.isPinned(path)
    }

    // MARK: - Content (single page or Compare grid)

    @ViewBuilder
    private var content: some View {
        if viewModel.isComparing {
            compareGrid
        } else if let path = viewModel.selectedPath {
            WikiPageReaderBody(
                viewModel: viewModel,
                path: path,
                onNavigate: { viewModel.navigate(to: $0) }
            )
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiary)
            Text("Select a page")
                .font(.callout)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compare grid

    private var compareGrid: some View {
        let paths = viewModel.comparePaths
        let columns = paths.count <= 1 ? 1 : 2
        let rows = gridColumns(count: columns)
        return LazyVGrid(columns: rows, spacing: 1) {
            ForEach(paths, id: \.self) { path in
                compareTile(path: path)
            }
        }
        .background(Theme.border) // 1px gutters show through as seams
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func gridColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 1), count: count)
    }

    private func compareTile(path: String) -> some View {
        let page = viewModel.graph.pages.first { $0.path == path }
        let isActive = viewModel.selectedPath == path
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.accent : Theme.tertiary)
                    .frame(width: 6, height: 6)
                Text(page?.title ?? displayName(for: path))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { viewModel.unpin(path) } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from comparison")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(isActive ? Theme.surfaceHover : Theme.surface.opacity(0.6))
            Divider()
            WikiPageReaderBody(
                viewModel: viewModel,
                path: path,
                // A link tap in any tile moves the shared current page — the
                // one place navigation happens. Selecting a pinned tile's page
                // makes it active without disturbing the pinned set.
                onNavigate: { viewModel.navigate(to: $0) }
            )
        }
        .frame(minHeight: 240)
        .background(Theme.background)
        .contentShape(Rectangle())
        .onTapGesture { if !isActive { viewModel.navigate(to: path) } }
    }

    // MARK: - Divider

    private var divider: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.secondary.opacity(0.5))
                .frame(width: 3, height: Self.gripHeight)
        }
        .frame(width: Self.dividerWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(Theme.background)
        .gesture(dividerDrag)
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
    }

    private var dividerDrag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartWidth ?? viewModel.readerWidth
                if dragStartWidth == nil { dragStartWidth = start }
                // Dragging the divider LEFT widens the right-docked panel, so a
                // negative x-translation adds width.
                viewModel.setReaderWidth(start - value.translation.width, surfaceWidth: surfaceWidth)
            }
            .onEnded { _ in dragStartWidth = nil }
    }

    private func displayName(for path: String?) -> String {
        guard let path else { return "Select a page" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
#endif
