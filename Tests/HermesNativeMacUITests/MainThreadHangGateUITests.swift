import XCTest

/// The macOS main-thread hang gate. Launches the app with `--hang-fatal` so the
/// MainThreadWatchdog escalates ANY >250ms main-thread stall to an
/// `assertionFailure` — which crashes the app, so this test observes the crash
/// (app no longer running / no longer responding) and fails.
///
/// Every beachball this app has shipped was on macOS. This runs the launch +
/// early-navigation path under the fatal watchdog so a stall introduced by a
/// new view/perf change fails the PR instead of reaching a user. It's hermetic
/// (no gateway) — it exercises the paths reachable without a backend; the lint
/// rules (no_heavy_work_in_view_body etc.) cover the pattern at author time,
/// and this covers the runtime run-loop the rules can't see.
internal final class MainThreadHangGateUITests: XCTestCase {

    @MainActor
    internal func testLaunchAndOnboardingDoNotHangMainThread() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        // --hang-fatal: a main-thread stall >250ms trips assertionFailure.
        // --uitest: hermetic launch (no gateway auto-config).
        app.launchArguments = ["--uitest", "--hang-fatal"]
        app.launchEnvironment = [
            "HERMES_NATIVE_GATEWAY_URL": "",
            "HERMES_NATIVE_API_KEY": "",
            "API_SERVER_KEY": ""
        ]
        app.launch()

        // UI-agnostic on purpose: this gate isn't about WHAT renders, it's
        // about whether the app's main run loop survives launch + settle under
        // the fatal watchdog. A >250ms main-thread stall trips assertionFailure
        // → the app crashes → `app.state` drops out of .runningForeground. So
        // we let it run, give the launch/first-render run-loop turns time to
        // complete, and assert the app is still alive.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App should launch and reach the foreground under --hang-fatal"
        )

        // Let first-render + any deferred work settle, then confirm still alive.
        // A hang during this window would have killed the process.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must stay alive — a --hang-fatal assertion would have crashed it")
    }
}
