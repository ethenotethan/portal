#if os(macOS)
import SwiftUI

/// The floating doc cards over the wiki graph (macOS). Each card is a free-form
/// panel the user drags by its header and resizes from any edge or corner —
/// clicking a node opens a card, clicking another node adds a second, and each
/// card carries its own page + history. The graph stays fully alive behind and
/// around the cards.
///
/// This is an overlay layer WITHIN WikiGraphView (Option A), not a separate
/// window: frames live in this layer's own coordinate space, so a drag reads a
/// stable translation and never feeds back on the moving card. The layout
/// mutates live during a drag (motion is immediate); nothing is persisted, so
/// there's no per-frame UserDefaults write.
internal struct WikiFloatingDocsLayer: View {
    @ObservedObject internal var viewModel: WikiGraphViewModel

    @State private var activeDrag: ActiveDrag?
    @State private var hoveredHandle: HandleRef?

    private struct ActiveDrag: Equatable {
        internal let id: UUID
        internal let handle: WikiDocHandle
        internal let startFrame: CGRect
    }

    private struct HandleRef: Equatable {
        internal let id: UUID
        internal let handle: WikiDocHandle
    }

    private static let coordSpace = "wikiFloatingDocsCanvas"
    private static let headerHeight: CGFloat = 34
    private static let edgeGrip: CGFloat = 9
    private static let cornerGrip: CGFloat = 20
    private static let edgeHandleThickness: CGFloat = 4
    private static let edgeHandleLength: CGFloat = 26
    private static let cornerHandleSize: CGFloat = 11

    internal var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // A pass-through backdrop: the graph shows through, and taps on
                // empty canvas fall to the graph below (no Color here).
                ForEach(viewModel.docLayout.cards) { card in
                    cardView(card, bounds: geo.size)
                }
            }
            .coordinateSpace(name: Self.coordSpace)
            .onChange(of: geo.size) { _, newSize in
                guard activeDrag == nil else { return }
                viewModel.docLayout = viewModel.docLayout.clamped(to: newSize)
            }
        }
        // Only intercept touches where a card actually is; empty regions stay
        // with the graph. (A ZStack of offset frames already does this — there's
        // no full-canvas hit target.)
        .allowsHitTesting(!viewModel.docLayout.isEmpty)
    }

    // MARK: - One card

    @ViewBuilder
    private func cardView(_ card: WikiDocCard, bounds: CGSize) -> some View {
        let isFocused = viewModel.docLayout.frontCard?.id == card.id
        VStack(spacing: 0) {
            header(card, bounds: bounds, isFocused: isFocused)
            Divider()
            WikiPageReaderBody(
                viewModel: viewModel,
                path: card.path,
                onNavigate: { viewModel.navigateCard(card.id, to: $0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(width: card.frame.width, height: card.frame.height)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: isFocused ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0.2), radius: isFocused ? 14 : 7, y: 3)
        .overlay(resizeGrips(card, bounds: bounds, isFocused: isFocused))
        .offset(x: card.frame.minX, y: card.frame.minY)
        .simultaneousGesture(TapGesture().onEnded { viewModel.focusCard(card.id) })
    }

    private func header(_ card: WikiDocCard, bounds: CGSize, isFocused: Bool) -> some View {
        let page = viewModel.graph.pages.first { $0.path == card.path }
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.secondary : Theme.tertiary)

            Button {
                viewModel.cardGoBack(card.id)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!card.canGoBack)

            Button {
                viewModel.cardGoForward(card.id)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!card.canGoForward)

            VStack(alignment: .leading, spacing: 1) {
                Text(page?.title ?? displayName(for: card.path))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(card.path)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if page != nil {
                Button {
                    // Focus this card first so the shared selection points at
                    // ITS page, then center that node — otherwise a background
                    // card's button would center the front card's node.
                    viewModel.focusCard(card.id)
                    viewModel.showCurrentPageInGraph()
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
                .help("Center this page's node in the graph")
            }

            Button {
                viewModel.closeCard(card.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.headerHeight)
        .frame(maxWidth: .infinity)
        .background(isFocused ? Theme.surfaceHover : Theme.surface.opacity(0.6))
        .contentShape(Rectangle())
        .gesture(dragGesture(.move, card: card, bounds: bounds))
        .pointerStyleGrab()
    }

    // MARK: - Resize grips (8 edges + corners)

    private func resizeGrips(_ card: WikiDocCard, bounds: CGSize, isFocused: Bool) -> some View {
        ZStack {
            grip(card, .top, bounds: bounds, isFocused: isFocused)
                .frame(height: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            grip(card, .bottom, bounds: bounds, isFocused: isFocused)
                .frame(height: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            grip(card, .leading, bounds: bounds, isFocused: isFocused)
                .frame(width: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            grip(card, .trailing, bounds: bounds, isFocused: isFocused)
                .frame(width: Self.edgeGrip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            corner(card, .topLeading, bounds: bounds, alignment: .topLeading, isFocused: isFocused)
            corner(card, .topTrailing, bounds: bounds, alignment: .topTrailing, isFocused: isFocused)
            corner(card, .bottomLeading, bounds: bounds, alignment: .bottomLeading, isFocused: isFocused)
            corner(card, .bottomTrailing, bounds: bounds, alignment: .bottomTrailing, isFocused: isFocused)
        }
    }

    private func grip(_ card: WikiDocCard, _ handle: WikiDocHandle, bounds: CGSize, isFocused: Bool) -> some View {
        let isHot = hoveredHandle == HandleRef(id: card.id, handle: handle)
        let horizontal = handle == .top || handle == .bottom
        return ZStack {
            Color.clear
            if isFocused {
                Capsule()
                    .fill(isHot ? Theme.accent : Theme.secondary.opacity(0.7))
                    .frame(
                        width: horizontal ? Self.edgeHandleLength : Self.edgeHandleThickness,
                        height: horizontal ? Self.edgeHandleThickness : Self.edgeHandleLength
                    )
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(handle, card: card, bounds: bounds))
        .onHover { inside in setHover(inside, card: card, handle: handle) }
        .pointerStyleResize(handle)
    }

    private func corner(
        _ card: WikiDocCard,
        _ handle: WikiDocHandle,
        bounds: CGSize,
        alignment: Alignment,
        isFocused: Bool
    ) -> some View {
        let isHot = hoveredHandle == HandleRef(id: card.id, handle: handle)
        return ZStack {
            Color.clear
            if isFocused {
                Circle()
                    .fill(isHot ? Theme.accent : Theme.surface)
                    .overlay(Circle().stroke(isHot ? Theme.accent : Theme.secondary, lineWidth: 1.5))
                    .frame(width: Self.cornerHandleSize, height: Self.cornerHandleSize)
            }
        }
        .frame(width: Self.cornerGrip, height: Self.cornerGrip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .gesture(dragGesture(handle, card: card, bounds: bounds))
        .onHover { inside in setHover(inside, card: card, handle: handle) }
        .pointerStyleResize(handle)
    }

    private func setHover(_ inside: Bool, card: WikiDocCard, handle: WikiDocHandle) {
        let ref = HandleRef(id: card.id, handle: handle)
        if inside {
            hoveredHandle = ref
        } else if hoveredHandle == ref {
            hoveredHandle = nil
        }
    }

    // MARK: - Drag / resize gesture

    private func dragGesture(_ handle: WikiDocHandle, card: WikiDocCard, bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordSpace))
            .onChanged { value in
                // First change of a drag: capture the start frame once and raise
                // the card. Subsequent changes recompute from this frame, so
                // translation never accumulates rounding error.
                if activeDrag?.id != card.id || activeDrag?.handle != handle {
                    activeDrag = ActiveDrag(id: card.id, handle: handle, startFrame: card.frame)
                    viewModel.focusCard(card.id)
                }
                guard let start = activeDrag?.startFrame else { return }
                let newFrame = WikiDocResizeMath.apply(
                    handle: handle,
                    startFrame: start,
                    translation: value.translation,
                    bounds: bounds
                )
                viewModel.docLayout.setFrame(newFrame, for: card.id)
            }
            .onEnded { _ in
                activeDrag = nil
            }
    }

    private func displayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - Pointer style helpers

private extension View {
    @ViewBuilder
    func pointerStyleResize(_ handle: WikiDocHandle) -> some View {
        self.onHover { inside in
            if inside {
                Self.resizeCursor(for: handle).set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    @ViewBuilder
    func pointerStyleGrab() -> some View {
        self.onHover { inside in
            if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
    }

    static func resizeCursor(for handle: WikiDocHandle) -> NSCursor {
        switch handle {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing, .move: return .crosshair
        }
    }
}
#endif
