#if os(macOS)
import Foundation
import Testing
@testable import Portal

/// The suspend/resume state machine's guard rails. The window-owning paths
/// need a real screen and a fullscreen transition, so they're exercised by
/// hand; what a unit test CAN pin down is that the controller never lies
/// about a world being available to return to, and that the no-window paths
/// are safe no-ops rather than crashes.
@Suite("Artifact Fullscreen Suspend", .serialized)
@MainActor
internal struct ArtifactFullscreenSuspendTests {

    @Test("with no presentation, suspend and resume are safe no-ops")
    internal func suspendResumeWithoutWindowAreNoOps() {
        let controller = ArtifactFullscreenWindowController.shared
        controller.close()

        controller.suspend()
        #expect(controller.suspendedWorldTitle == nil)

        controller.resume()
        #expect(controller.suspendedWorldTitle == nil)
        #expect(!controller.isPresenting)
    }

    @Test("close clears any suspended-world state")
    internal func closeClearsSuspension() {
        let controller = ArtifactFullscreenWindowController.shared
        controller.close()
        #expect(controller.suspendedWorldTitle == nil)
        #expect(!controller.isPresenting)
    }
}
#endif
