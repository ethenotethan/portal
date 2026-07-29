import XCTest

final class PortalOfflineSmokeUITests: XCTestCase {
    @MainActor
    func testOnboardingRendersWithoutGatewaySecrets() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launchEnvironment = [
            // Keep this test hermetic: do not auto-configure gateway settings.
            "PORTAL_GATEWAY_URL": "",
            "PORTAL_API_KEY": "",
            "API_SERVER_KEY": ""
        ]
        app.launch()

        dismissNotificationPromptIfNeeded()

        XCTAssertTrue(
            app.staticTexts["Connect to your harness"].waitForExistence(timeout: 15),
            "Onboarding should render when no CI gateway secrets are provided"
        )
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 5), "Connect button should be visible")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "offline-onboarding"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
