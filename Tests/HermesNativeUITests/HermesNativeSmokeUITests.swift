import XCTest

final class HermesNativeSmokeUITests: XCTestCase {
    @MainActor
    func testConnectAndSendHello() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        var launchEnvironment = [
            "HERMES_NATIVE_GATEWAY_URL": "ws://192.168.1.194:18642/v1/ws"
        ]
        if let sessionKey = ProcessInfo.processInfo.environment["HERMES_SESSION_KEY"] {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = sessionKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 3) {
            allowButton.tap()
        }

        let connectButton = app.buttons["connectButton"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10), "Connect button should be visible")
        connectButton.tap()

        // Wait until we are no longer on the onboarding form. If this fails,
        // attach the visible debug log for connection triage.
        let sessions = app.staticTexts["Sessions"]
        let connected = sessions.waitForExistence(timeout: 20)
        let beforeHello = XCUIScreen.main.screenshot()
        let beforeAttachment = XCTAttachment(screenshot: beforeHello)
        beforeAttachment.name = connected ? "01-connected-sessions" : "01-connect-failed"
        beforeAttachment.lifetime = .keepAlways
        add(beforeAttachment)
        if !connected {
            let debugText = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
            let debugAttachment = XCTAttachment(string: debugText)
            debugAttachment.name = "connect-failed-accessibility-text"
            debugAttachment.lifetime = .keepAlways
            add(debugAttachment)
        }
        XCTAssertTrue(connected, "Sessions UI should appear after connecting")

        // Create/open an owned chat session from the iOS Sessions list.
        let plusButton = app.buttons["newSessionButton"]
        let addButton = app.buttons["Add"]
        let anyToolbarButton = app.buttons.element(boundBy: 0)
        if plusButton.waitForExistence(timeout: 3) {
            plusButton.tap()
        } else if addButton.waitForExistence(timeout: 1) {
            addButton.tap()
        } else if anyToolbarButton.waitForExistence(timeout: 2) {
            anyToolbarButton.tap()
        }
        if app.staticTexts["New Chat"].waitForExistence(timeout: 10) {
            app.staticTexts["New Chat"].tap()
        } else if app.cells.element(boundBy: 0).waitForExistence(timeout: 3) {
            app.cells.element(boundBy: 0).tap()
        }

        let input = app.textFields["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), "Could not find chat input")
        input.tap()
        input.typeText("hello")

        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button should exist")
        sendButton.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "hello")).element.waitForExistence(timeout: 10), "Sent hello should appear in transcript")

        sleep(5)
        let afterHello = XCUIScreen.main.screenshot()
        let afterAttachment = XCTAttachment(screenshot: afterHello)
        afterAttachment.name = "02-after-hello"
        afterAttachment.lifetime = .keepAlways
        add(afterAttachment)
    }
}
