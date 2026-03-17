import XCTest
import UIKit

final class AccessibilitySmokeTests: XCTestCase {

    private let accessibilityCategory = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDisconnectedAccessibilityFlow() {
        let app = launchApp(scenarioArgument: "--uitest-disconnected")
        defer { app.terminate() }

        XCTAssertTrue(waitForIdentifier("dashboardScreen", in: app))

        app.buttons["connectButton"].tap()
        XCTAssertTrue(waitForIdentifier("scanSheet", in: app))
        app.buttons["Cancel"].tap()

        app.buttons["tabData"].tap()
        XCTAssertTrue(waitForIdentifier("historyScreen", in: app))

        app.buttons["tabDevices"].tap()
        XCTAssertTrue(waitForIdentifier("devicesScreen", in: app))
    }

    func testConnectedAccessibilityFlow() {
        let app = launchApp(scenarioArgument: "--uitest-connected")
        defer { app.terminate() }

        XCTAssertTrue(waitForIdentifier("dashboardScreen", in: app))

        app.buttons["tabData"].tap()
        XCTAssertTrue(waitForIdentifier("historyScreen", in: app))
        XCTAssertTrue(app.staticTexts["Latest Value"].waitForExistence(timeout: 5))

        app.buttons["tabDevices"].tap()
        XCTAssertTrue(waitForIdentifier("devicesScreen", in: app))

        let settingsButton = app.buttons["Device settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        XCTAssertTrue(waitForIdentifier("deviceSettingsScreen", in: app))

        let backButton = app.navigationBars.buttons["Devices"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        app.buttons["tabAdvanced"].tap()
        XCTAssertTrue(waitForIdentifier("advancedScreen", in: app))
    }

    @discardableResult
    private func launchApp(scenarioArgument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            scenarioArgument,
            "-UIPreferredContentSizeCategoryName",
            accessibilityCategory,
        ]
        app.launch()
        return app
    }

    private func waitForIdentifier(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
            .waitForExistence(timeout: timeout)
    }
}
