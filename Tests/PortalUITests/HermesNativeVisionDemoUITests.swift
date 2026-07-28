import XCTest

final class PortalVisionDemoUITests: XCTestCase {
    @MainActor
    func testVisionDemoSessionMissionControl() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]

        let environment = ProcessInfo.processInfo.environment
        let gatewayURL = environment["PORTAL_GATEWAY_URL"] ?? "ws://192.168.1.194:18642/v1/ws"
        var launchEnvironment = ["PORTAL_GATEWAY_URL": gatewayURL]
        if let apiKey = environment["PORTAL_API_KEY"], !apiKey.isEmpty {
            launchEnvironment["PORTAL_API_KEY"] = apiKey
        } else if let apiServerKey = environment["API_SERVER_KEY"], !apiServerKey.isEmpty {
            launchEnvironment["PORTAL_API_KEY"] = apiServerKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()

        dismissNotificationPromptIfNeeded()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 25), "Sessions screen should be visible")
        addScreenshot("01-sessions")

        openNewSession(in: app)
        send("hello", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "hello")).element.waitForExistence(timeout: 10))
        addScreenshot("02-first-session-hello")

        backToSessions(app)
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10))
        addScreenshot("03-back-to-sessions")

        openNewSession(in: app)
        let delegationPrompt = "For iOS demo: use delegate_task in batch mode to spawn exactly two tiny sub-agents. Task A: reply with one sentence about apples. Task B: reply with one sentence about bananas. Then summarize both in one short sentence."
        send(delegationPrompt, in: app)

        // Wait until the agent visibly enters a delegated/tooling turn. Mission Control can be opened while it runs.
        let delegated = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "delegate", "subagent", "tool")).element.waitForExistence(timeout: 60)
        addScreenshot(delegated ? "04-second-session-subagents-running" : "04-second-session-after-delegation-prompt")

        backToSessions(app)
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10))
        addScreenshot("05-sessions-before-mission-control")

        openMissionControlForTopOwnedSession(in: app)
        XCTAssertTrue(app.staticTexts["Agents"].waitForExistence(timeout: 10), "Mission Control Agents tab should be visible")

        // Wait for visible tree node metadata: root plus child count, L1 badges, or node count.
        _ = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "nodes", "L1", "apples")).element.waitForExistence(timeout: 60)
        addScreenshot("06-mission-control-agents")

        // Tap a visible node to prove the panel is interactive.
        let tappable = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "apples", "bananas", "iOS demo")).element
        if tappable.waitForExistence(timeout: 5) {
            tappable.tap()
        }
        addScreenshot("07-mission-control-node-clicked")
    }

    @MainActor
    private func openNewSession(in app: XCUIApplication) {
        let startButton = app.buttons["startNewChatButton"].firstMatch
        let toolbarButton = app.buttons["newSessionButton"].firstMatch
        if startButton.waitForExistence(timeout: 3) {
            startButton.tap()
        } else {
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 10), "New session button should be visible")
            toolbarButton.tap()
        }
        XCTAssertTrue(resolveChatInput(in: app).waitForExistence(timeout: 15), "Chat input should appear after creating session")
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let input = resolveChatInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 15), "Chat input should exist")
        input.tap()
        input.typeText(text)
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button should exist")
        send.tap()
    }

    @MainActor
    private func resolveChatInput(in app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["chatInput"]
        if textView.exists { return textView }
        return app.textFields["chatInput"]
    }

    @MainActor
    private func backToSessions(_ app: XCUIApplication) {
        if app.staticTexts["Sessions"].exists { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
    }

    @MainActor
    private func openMissionControlForTopOwnedSession(in app: XCUIApplication) {
        // Prefer the most recent owned session row near the top of My Sessions.
        let firstCell = app.cells.element(boundBy: 0)
        XCTAssertTrue(firstCell.waitForExistence(timeout: 10), "Expected at least one session row")
        firstCell.swipeRight()
        let mission = app.buttons["Mission Control"]
        if mission.waitForExistence(timeout: 5) {
            mission.tap()
            return
        }
        // Fallback: context menu / long press may expose the same action.
        firstCell.press(forDuration: 1.0)
        XCTAssertTrue(mission.waitForExistence(timeout: 5), "Mission Control action should appear")
        mission.tap()
    }

    @MainActor
    private func dismissNotificationPromptIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don’t Allow"]
        if dontAllow.waitForExistence(timeout: 3) {
            dontAllow.tap()
            return
        }
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 1) {
            allow.tap()
        }
    }

    @MainActor
    private func addScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
