import XCTest

final class PortalGatewayConnectionUITests: XCTestCase {
    @MainActor
    func testConnectsToLocalHermesGateway() throws {
        continueAfterFailure = false

        let app = launchConfiguredApp()
        dismissNotificationPromptIfNeeded()

        let connected = waitForSessionsUI(in: app)
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
    func testNewSessionPushesSingleChatDestination() throws {
        continueAfterFailure = false

        let app = launchConfiguredApp()
        dismissNotificationPromptIfNeeded()
        XCTAssertTrue(waitForSessionsUI(in: app), "Sessions UI should appear after connecting to local Hermes gateway")

        let firstBackCount = createSessionAndReturnBackButtonCount(in: app)
        let firstScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        firstScreenshot.name = "new-session-single-destination-first"
        firstScreenshot.lifetime = .keepAlways
        add(firstScreenshot)
        XCTAssertEqual(firstBackCount, 1, "New Session should push exactly one chat destination")

        navigateBackToSessions(in: app)
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5), "Should return to Sessions after one Back tap")

        let secondBackCount = createSessionAndReturnBackButtonCount(in: app)
        let secondScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        secondScreenshot.name = "new-session-single-destination-second"
        secondScreenshot.lifetime = .keepAlways
        add(secondScreenshot)
        XCTAssertEqual(secondBackCount, 1, "Repeated New Session taps should still push exactly one chat destination")
    }

    @MainActor
    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]

        let environment = ProcessInfo.processInfo.environment
        let gatewayURL = environment["PORTAL_GATEWAY_URL"] ?? "ws://127.0.0.1:18642/v1/ws"
        var launchEnvironment = ["PORTAL_GATEWAY_URL": gatewayURL]
        if let apiKey = environment["PORTAL_API_KEY"], !apiKey.isEmpty {
            launchEnvironment["PORTAL_API_KEY"] = apiKey
        } else if let apiServerKey = environment["API_SERVER_KEY"], !apiServerKey.isEmpty {
            launchEnvironment["PORTAL_API_KEY"] = apiServerKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()
        return app
    }

    @MainActor
    private func waitForSessionsUI(in app: XCUIApplication) -> Bool {
        let sessions = app.staticTexts["Sessions"]
        if !sessions.waitForExistence(timeout: 3) {
            let connectButton = app.buttons["connectButton"]
            if connectButton.waitForExistence(timeout: 10) {
                connectButton.tap()
            }
        }
        return sessions.waitForExistence(timeout: 25)
    }

    @MainActor
    private func createSessionAndReturnBackButtonCount(in app: XCUIApplication) -> Int {
        let startButton = app.buttons["startNewChatButton"].firstMatch
        let newSessionButton = app.buttons["newSessionButton"].firstMatch
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        } else {
            XCTAssertTrue(newSessionButton.waitForExistence(timeout: 10), "New Session button should be visible")
            newSessionButton.tap()
        }

        let textView = app.textViews["chatInput"]
        let textField = app.textFields["chatInput"]
        let chatReady = textView.waitForExistence(timeout: 8) || textField.waitForExistence(timeout: 7)
        if !chatReady {
            let debugAttachment = XCTAttachment(string: app.debugDescription)
            debugAttachment.name = "new-session-chat-input-missing-accessibility-tree"
            debugAttachment.lifetime = .keepAlways
            add(debugAttachment)
        }
        XCTAssertTrue(chatReady, "Chat input should appear after New Session")

        return backButtonCount(in: app)
    }

    @MainActor
    private func backButtonCount(in app: XCUIApplication) -> Int {
        app.navigationBars.buttons.allElementsBoundByIndex.filter { button in
            let label = button.label
            return label == "Back" || label == "Sessions"
        }.count
    }

    @MainActor
    private func navigateBackToSessions(in app: XCUIApplication) {
        let sessionsBackButton = app.navigationBars.buttons["Sessions"].firstMatch
        if sessionsBackButton.waitForExistence(timeout: 3) {
            sessionsBackButton.tap()
            return
        }

        let backButton = app.navigationBars.buttons["Back"].firstMatch
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        }
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
