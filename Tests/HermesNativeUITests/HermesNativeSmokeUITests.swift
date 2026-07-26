import XCTest
#if os(iOS)
import UIKit
#endif

final class HermesNativeSmokeUITests: XCTestCase {
    @MainActor
    func testConnectAndSendHello() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]

        let environment = ProcessInfo.processInfo.environment
        let gatewayURL = environment["HERMES_NATIVE_GATEWAY_URL"] ?? "ws://192.168.1.194:18642/v1/ws"
        var launchEnvironment = [
            "HERMES_NATIVE_GATEWAY_URL": gatewayURL
        ]
        if let apiKey = environment["HERMES_NATIVE_API_KEY"], !apiKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiKey
        } else if let apiServerKey = environment["API_SERVER_KEY"], !apiServerKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiServerKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()

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

        let sessions = app.staticTexts["Sessions"]
        if !sessions.waitForExistence(timeout: 3) {
            let connectButton = app.buttons["connectButton"]
            XCTAssertTrue(connectButton.waitForExistence(timeout: 10), "Connect button should be visible")
            connectButton.tap()
        }

        // Wait until we are no longer on the onboarding form. If this fails,
        // attach the visible debug log for connection triage.
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
        XCTAssertTrue(app.tabBars.buttons["Artifacts"].waitForExistence(timeout: 5), "Artifacts tab should be visible on iOS")

        // Create/open an owned chat session from the in-app control so the
        // original launch environment (gateway URL + API key) stays attached.
        let startButton = app.buttons["startNewChatButton"].firstMatch
        let plusButton = app.buttons["newSessionButton"].firstMatch
        if startButton.waitForExistence(timeout: 3) {
            startButton.tap()
        } else {
            XCTAssertTrue(plusButton.waitForExistence(timeout: 10), "New Session button should be visible")
            plusButton.tap()
        }
        if app.staticTexts["New Chat"].waitForExistence(timeout: 10) {
            app.staticTexts["New Chat"].tap()
        } else if app.cells.element(boundBy: 0).waitForExistence(timeout: 3) {
            app.cells.element(boundBy: 0).tap()
        }

        let input = app.textViews["chatInput"]
        if !input.waitForExistence(timeout: 5) {
            // Axis-based SwiftUI TextField may bridge as either TextView or TextField.
            let fallbackInput = app.textFields["chatInput"]
            _ = fallbackInput.waitForExistence(timeout: 15)
        }
        let resolvedInput = input.exists ? input : app.textFields["chatInput"]
        if !resolvedInput.waitForExistence(timeout: 1) {
            let afterCreate = XCUIScreen.main.screenshot()
            let createAttachment = XCTAttachment(screenshot: afterCreate)
            createAttachment.name = "02-chat-input-missing"
            createAttachment.lifetime = .keepAlways
            add(createAttachment)

            let debugText = app.debugDescription
            let debugAttachment = XCTAttachment(string: debugText)
            debugAttachment.name = "chat-input-missing-accessibility-tree"
            debugAttachment.lifetime = .keepAlways
            add(debugAttachment)
        }
        XCTAssertTrue(resolvedInput.exists, "Could not find chat input")
        resolvedInput.tap()
        resolvedInput.typeText("hello")

        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button should exist")
        sendButton.tap()

        let helloPredicate = NSPredicate(format: "label CONTAINS[c] %@", "hello")
        let helloVisible = app.staticTexts.containing(helloPredicate).element.waitForExistence(timeout: 10)
        let afterHello = XCUIScreen.main.screenshot()
        let afterAttachment = XCTAttachment(screenshot: afterHello)
        afterAttachment.name = helloVisible ? "03-after-hello" : "03-hello-missing"
        afterAttachment.lifetime = .keepAlways
        add(afterAttachment)

        if !helloVisible {
            let debugAttachment = XCTAttachment(string: app.debugDescription)
            debugAttachment.name = "hello-missing-accessibility-tree"
            debugAttachment.lifetime = .keepAlways
            add(debugAttachment)
        }
        XCTAssertTrue(helloVisible, "Sent hello should appear in transcript")
    }

    @MainActor
    func testConcurrentSubagentControlPlaneDemo() throws {
        continueAfterFailure = false

        let app = launchConfiguredApp()
        handleNotificationPrompt()
        XCTAssertTrue(waitForSessionsUI(in: app), "Sessions UI should appear after connecting")

        addDemoScreenshot(name: "00-sessions-ready", app: app)

        createSessionAndSubmitPrompt(
            in: app,
            prompt: "Spawn five concurrent subagents. Each one should run a short shell loop that prints hello world every 10 seconds for 1 minute. Keep all five running concurrently."
        )
        addDemoScreenshot(name: "01-session-a-prompt-submitted", app: app)
        Thread.sleep(forTimeInterval: 12)

        navigateBackIfPossible(in: app)
        createSessionAndSubmitPrompt(
            in: app,
            prompt: "Spawn five concurrent subagents. Each one should run a short shell loop that prints hello world every 10 seconds for 1 minute. Keep all five running concurrently."
        )
        addDemoScreenshot(name: "02-session-b-prompt-submitted", app: app)
        Thread.sleep(forTimeInterval: 12)

        navigateBackIfPossible(in: app)
        addDemoScreenshot(name: "03-sessions-list-two-running", app: app)
    }

    @MainActor
    private func addDemoScreenshot(name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]

        let environment = ProcessInfo.processInfo.environment
        let gatewayURL = environment["HERMES_NATIVE_GATEWAY_URL"] ?? "ws://192.168.1.194:18642/v1/ws"
        var launchEnvironment = [
            "HERMES_NATIVE_GATEWAY_URL": gatewayURL
        ]
        if let apiKey = environment["HERMES_NATIVE_API_KEY"], !apiKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiKey
        } else if let apiServerKey = environment["API_SERVER_KEY"], !apiServerKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiServerKey
            launchEnvironment["API_SERVER_KEY"] = apiServerKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()
        return app
    }

    @MainActor
    private func handleNotificationPrompt() {
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
    private func navigateBackIfPossible(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.matching(NSPredicate(format: "label != %@", "New Session")).element(boundBy: 0)
        if backButton.exists && backButton.isHittable {
            backButton.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    @MainActor
    private func createSessionAndSubmitPrompt(in app: XCUIApplication, prompt: String) {
        navigateBackIfPossible(in: app)

        let plusButton = app.buttons["newSessionButton"].firstMatch
        let startButton = app.buttons["startNewChatButton"].firstMatch
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        } else {
            XCTAssertTrue(plusButton.waitForExistence(timeout: 10), "New Session button should be visible")
            plusButton.tap()
        }

        let input = resolveChatInput(in: app, timeout: 20)
        XCTAssertTrue(input.exists, "chat input should exist")
        input.tap()
        input.typeText(prompt)

        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "send button should exist")
        sendButton.tap()
    }

    @MainActor
    private func resolveChatInput(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement {
        let textView = app.textViews["chatInput"]
        if textView.waitForExistence(timeout: timeout / 2) { return textView }
        let textField = app.textFields["chatInput"]
        _ = textField.waitForExistence(timeout: timeout / 2)
        return textField
    }

    @MainActor
    private func paste(_ text: String, into input: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.string = text
        input.press(forDuration: 1.0)
        let pasteMenu = app.menuItems["Paste"]
        if pasteMenu.waitForExistence(timeout: 3) {
            pasteMenu.tap()
        } else {
            input.typeText(text)
        }
    }

    @MainActor
    private func openMissionControlForActiveSession(in app: XCUIApplication) {
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        coordinate.press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func closePresentedSheet(in app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) {
            done.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
