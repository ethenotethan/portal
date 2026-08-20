import SwiftUI

// MARK: - Canvas hit-testing & tap selection
//
// The pointer surface for the 2D canvas: mapping a screen point to a node,
// and the tap → select/open (or empty-canvas deselect) flow. Split from the
// core view model to keep it under the body/file-length ceiling; hover and
// the `noteInteraction` motion signal stay in the core beside the state they
// mutate.

extension WikiGraphViewModel {

    /// The topmost node under a canvas point in model space, or nil for empty
    /// canvas. Walks back-to-front so the visually-on-top node wins a tie.
    internal func hitTest(point: CGPoint) -> Int? {
        let mx = (point.width - panOffset.width) / zoom
        let my = (point.height - panOffset.height) / zoom
        let modelPoint = CGPoint(x: mx, y: my)
        for (index, node) in simNodes.enumerated().reversed() {
            let r = nodeRadius(for: node.type) + 4
            if abs(node.position.x - modelPoint.x) < r && abs(node.position.y - modelPoint.y) < r { return index }
        }
        return nil
    }

    internal func handleTap(at point: CGPoint) {
        if let index = hitTest(point: point) {
            activateNode(index)
        } else {
            deactivateSelection()
        }
    }

    /// Selection-driven reader: tapping a node (2D or 3D) selects it and
    /// opens the reader over the always-alive graph.
    internal func activateNode(_ index: Int) {
        selectNode(index)
        openReaderForSelection()
    }

    /// Tapping empty canvas deselects and closes the reader — back to the
    /// full-bleed graph. Path/history survive for the sidebar and timeline.
    internal func deactivateSelection() {
        selectedNodeIndex = nil
        showPageDetail = false
        readerFullscreen = false
    }

    internal func deselectNode() { selectedNodeIndex = nil }
}
