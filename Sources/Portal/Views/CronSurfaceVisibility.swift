import SwiftUI

extension View {
    /// Declare this view a surface that shows cron state (job list, dashboard,
    /// runtime dataflow graph). `CronPoller` issues `cron.graph` / `cron.manage`
    /// only while at least one such surface is on screen, and refreshes once
    /// when the first appears — so the gateway hears nothing about cron from a
    /// window that isn't looking at it.
    internal func cronSurfaceVisible() -> some View {
        modifier(CronSurfaceVisibilityModifier())
    }
}

private struct CronSurfaceVisibilityModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { cronSurfaceInterest.surfaceAppeared() }
            .onDisappear { cronSurfaceInterest.surfaceDisappeared() }
    }
}
