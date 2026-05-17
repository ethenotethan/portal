import XCTest

final class HermesNativeE2ETests: XCTestCase {

    private var gatewayURL: String {
        ProcessInfo.processInfo.environment["HERMES_NATIVE_GATEWAY_URL"] ?? "ws://127.0.0.1:18642/v1/ws"
    }

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["HERMES_NATIVE_API_KEY"]
            ?? ProcessInfo.processInfo.environment["API_SERVER_KEY"]
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        var env = ["HERMES_NATIVE_GATEWAY_URL": gatewayURL]
        if let key = apiKey, !key.isEmpty {
            env["HERMES_NATIVE_API_KEY"] = key
        }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func connectToGateway(_ app: XCUIApplication) -> Bool {
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
    private func createNewSession(_ app: XCUIApplication) {
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
        _ = textView.waitForExistence(timeout: 8) || textField.waitForExistence(timeout: 7)
    }

    @MainActor
    private func typeMessage(_ app: XCUIApplication, text: String) {
        let textView = app.textViews["chatInput"].firstMatch
        let textField = app.textFields["chatInput"].firstMatch
        if textView.waitForExistence(timeout: 3) {
            textView.tap()
            textView.typeText(text)
        } else if textField.waitForExistence(timeout: 3) {
            textField.tap()
            textField.typeText(text)
        }
    }

    @MainActor
    private func sendMessage(_ app: XCUIApplication) {
        let sendButton = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button should be visible")
        sendButton.tap()
    }

    @MainActor
    private func waitForResponse(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let stopButton = app.buttons["stopButton"].firstMatch
        if stopButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(stopButton.waitForNonExistence(timeout: timeout), "Agent should finish responding")
        }
        sleep(1)
        return true
    }

    @MainActor
    private func navigateBackToSessions(_ app: XCUIApplication) {
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
    private func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllowButton = springboard.buttons["Don't Allow"]
        if dontAllowButton.waitForExistence(timeout: 3) {
            dontAllowButton.tap()
        } else {
            let allowButton = springboard.buttons["Allow"]
            if allowButton.waitForExistence(timeout: 1) {
                allowButton.tap()
            }
        }
    }

    // MARK: - Core Chat Flow

    @MainActor
    func testCoreChatFlow_SendPromptReceiveResponse() throws {
        continueAfterFailure = false

        let app = launchApp()
        dismissNotificationPrompt()
        XCTAssertTrue(connectToGateway(app), "Should connect to gateway")
        createNewSession(app)

        typeMessage(app, text: "Reply with exactly: E2E_TEST_OK")
        sendMessage(app)

        let stopButton = app.buttons["stopButton"].firstMatch
        if stopButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(stopButton.waitForNonExistence(timeout: 30), "Agent should complete response")
        }

        sleep(2)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "core-chat-flow"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        navigateBackToSessions(app)
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5), "Should return to sessions")
    }

    @MainActor
    func testCoreChatFlow_MultipleMessagesInSession() throws {
        continueAfterFailure = false

        let app = launchApp()
        dismissNotificationPrompt()
        XCTAssertTrue(connectToGateway(app), "Should connect to gateway")
        createNewSession(app)

        typeMessage(app, text: "Reply with exactly: FIRST")
        sendMessage(app)
        waitForResponse(app)

        typeMessage(app, text: "Reply with exactly: SECOND")
        sendMessage(app)
        waitForResponse(app)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "multi-message-session"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        navigateBackToSessions(app)
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5), "Should return to sessions")
    }

    // MARK: - Session Management

    @MainActor
    func testSessionManagement_CreateAndNavigate() throws {
        continueAfterFailure = false

        let app = launchApp()
        dismissNotificationPrompt()
        XCTAssertTrue(connectToGateway(app), "Should connect to gateway")

        let startButton = app.buttons["startNewChatButton"].firstMatch
        let newSessionButton = app.buttons["newSessionButton"].firstMatch

        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        } else {
            XCTAssertTrue(newSessionButton.waitForExistence(timeout: 10), "New Session button should appear")
            newSessionButton.tap()
        }

        XCTAssertTrue(
            app.textViews["chatInput"].waitForExistence(timeout: 8)
                || app.textFields["chatInput"].waitForExistence(timeout: 7),
            "Chat input should appear in new session"
        )

        navigateBackToSessions(app)
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5), "Should return to sessions list")
    }

    @MainActor
    func testSessionManagement_MultipleSessions() throws {
        continueAfterFailure = false

        let app = launchApp()
        dismissNotificationPrompt()
        XCTAssertTrue(connectToGateway(app), "Should connect to gateway")

        for i in 1...3 {
            let startButton = app.buttons["startNewChatButton"].firstMatch
            let newSessionButton = app.buttons["newSessionButton"].firstMatch
            if startButton.waitForExistence(timeout: 2) {
                startButton.tap()
            } else {
                XCTAssertTrue(newSessionButton.waitForExistence(timeout: 10), "New Session button should appear (iteration \(i))")
                newSessionButton.tap()
            }

            let chatReady = app.textViews["chatInput"].waitForExistence(timeout: 8)
                || app.textFields["chatInput"].waitForExistence(timeout: 7)
            XCTAssertTrue(chatReady, "Session \(i) chat should open")

            navigateBackToSessions(app)
            XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5), "Should return to sessions (iteration \(i))")
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "multiple-sessions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: - Attach Button Visibility

    @MainActor
    func testAttachButtonVisibleWithoutCapabilityGating() throws {
        continueAfterFailure = false

        let app = launchApp()
        dismissNotificationPrompt()
        XCTAssertTrue(connectToGateway(app), "Should connect to gateway")
        createNewSession(app)

        let attachButton = app.buttons["attachFileButton"].firstMatch
        XCTAssertTrue(attachButton.waitForExistence(timeout: 10), "Attach button should always be visible regardless of gateway capabilities")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "attach-button-visible"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
