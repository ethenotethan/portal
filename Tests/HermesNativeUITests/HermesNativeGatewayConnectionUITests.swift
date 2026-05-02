import XCTest

final class HermesNativeGatewayConnectionUITests: XCTestCase {
    @MainActor
    func testConnectsToLocalHermesGateway() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]

        let environment = ProcessInfo.processInfo.environment
        let gatewayURL = environment["HERMES_NATIVE_GATEWAY_URL"] ?? "ws://127.0.0.1:18642/v1/ws"
        var launchEnvironment = ["HERMES_NATIVE_GATEWAY_URL": gatewayURL]
        if let apiKey = environment["HERMES_NATIVE_API_KEY"], !apiKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiKey
        } else if let apiServerKey = environment["API_SERVER_KEY"], !apiServerKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiServerKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()

        dismissNotificationPromptIfNeeded()

        let sessions = app.staticTexts["Sessions"]
        if !sessions.waitForExistence(timeout: 3) {
            let connectButton = app.buttons["connectButton"]
            XCTAssertTrue(connectButton.waitForExistence(timeout: 10), "Connect button should be visible")
            connectButton.tap()
        }

        let connected = sessions.waitForExistence(timeout: 25)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = connected ? "local-hermes-sessions" : "local-hermes-connect-failed"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        if !connected {
            let debugAttachment = XCTAttachment(string: app.debugDescription)
            debugAttachment.name = "local-hermes-connect-failed-accessibility-tree"
            debugAttachment.lifetime = .keepAlways
            add(debugAttachment)
        }

        XCTAssertTrue(connected, "Sessions UI should appear after connecting to local Hermes gateway")
    }

    @MainActor
    private func dismissNotificationPromptIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllowButton = springboard.buttons["Don’t Allow"]
        if dontAllowButton.waitForExistence(timeout: 3) {
            dontAllowButton.tap()
        } else {
            let allowButton = springboard.buttons["Allow"]
            if allowButton.waitForExistence(timeout: 1) {
                allowButton.tap()
            }
        }
    }
}
