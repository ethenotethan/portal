import CoreGraphics
import Foundation
import Testing
@testable import Portal

@MainActor
@Suite("Cron graph view model — selection & zoom")
internal struct CronGraphViewModelTests {

    private func seededVM() -> CronGraphViewModel {
        let vm = CronGraphViewModel()
        vm.simNodes = [
            CronGraphViewModel.SimNode(id: "job-a", position: .zero, kind: "cron", type: "cron", label: "A"),
            CronGraphViewModel.SimNode(id: "wiki-raw", position: .zero, kind: "artifact", type: "snapshot", label: "wiki raw"),
            CronGraphViewModel.SimNode(id: "job-b", position: .zero, kind: "cron", type: "cron", label: "B"),
        ]
        return vm
    }

    // MARK: - selectNode(withID:)

    @Test("selectNode(withID:) selects the node carrying that id")
    internal func selectByIDSelectsMatchingNode() {
        let vm = seededVM()
        vm.selectNode(withID: "wiki-raw")
        #expect(vm.selectedNodeIndex == 1)
    }

    @Test("selectNode(withID:) with an unknown id is a no-op")
    internal func selectByUnknownIDIsNoOp() {
        let vm = seededVM()
        vm.selectedNodeIndex = 0
        vm.selectNode(withID: "does-not-exist")
        #expect(vm.selectedNodeIndex == 0)

        vm.selectedNodeIndex = nil
        vm.selectNode(withID: "still-nope")
        #expect(vm.selectedNodeIndex == nil)
    }

    // MARK: - zoomAtPoint / zoomAtCenter

    @Test("zoomAtPoint scales zoom and keeps the anchor point fixed")
    internal func zoomAtPointHoldsAnchor() {
        let vm = CronGraphViewModel()
        vm.canvasSize = CGSize(width: 600, height: 400)
        vm.zoom = 1.0
        vm.panOffset = .zero
        let anchor = CGPoint(x: 100, y: 50)
        vm.zoomAtPoint(factor: 2.0, around: anchor)
        #expect(vm.zoom == 2.0)
        // pan compensates by point * (oldZoom - newZoom) = 100 * (1 - 2) = -100.
        #expect(vm.panOffset.width == -100)
        #expect(vm.panOffset.height == -50)
    }

    @Test("zoomAtPoint clamps to the usable [0.3, 5.0] range")
    internal func zoomClampsToRange() {
        let vm = CronGraphViewModel()
        vm.canvasSize = CGSize(width: 600, height: 400)
        vm.zoom = 1.0
        // Blow past the ceiling — repeated zoom-in never exceeds 5.0.
        for _ in 0..<20 { vm.zoomAtCenter(2.0) }
        #expect(vm.zoom == 5.0)
        // And past the floor — repeated zoom-out never drops below 0.3.
        for _ in 0..<40 { vm.zoomAtCenter(0.5) }
        #expect(vm.zoom == 0.3)
    }

    @Test("zoomAtPoint ignores non-finite or non-positive factors")
    internal func zoomIgnoresBadFactors() {
        let vm = CronGraphViewModel()
        vm.zoom = 1.4
        vm.zoomAtPoint(factor: 0, around: .zero)
        vm.zoomAtPoint(factor: -1, around: .zero)
        vm.zoomAtPoint(factor: .infinity, around: .zero)
        #expect(vm.zoom == 1.4)
    }
}
