import XCTest

/// Tab navigation smoke test after auto-connect (runs after VPN profile exists from warmup/connect tests).
final class AzadiTunnelFeatureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication(bundleIdentifier: "com.polamgh.ali.AzadiTunnel").terminate()
    }

    func testAllFeaturesAfterVPNConnect() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Post-connect feature tour requires a physical iOS device with an active VPN tunnel.")
        #endif
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-UITestAutoConnect", "-UITestForceBootstrap"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        acceptVPNAndDisclosure(app: app)

        let status = app.staticTexts["statusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let connected = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "label CONTAINS[c] %@", "Connected"),
            NSPredicate(format: "label CONTAINS[c] %@", "متصل")
        ])
        wait(for: [expectation(for: connected, evaluatedWith: status, handler: nil)], timeout: 180)

        for index in 0..<2 {
            app.tabBars.buttons.element(boundBy: index).tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "Tab \(index) failed")
        }

        openLogsFromSettings(app)
        XCTAssertTrue(app.buttons["copy_logs_button"].waitForExistence(timeout: 15))
    }

    private func openLogsFromSettings(_ app: XCUIApplication) {
        if app.tabBars.buttons["settingsTabBar"].waitForExistence(timeout: 5) {
            app.tabBars.buttons["settingsTabBar"].tap()
        } else {
            app.tabBars.buttons["Settings"].tap()
        }
        let link = app.buttons["logsSettingsLink"]
        if link.waitForExistence(timeout: 8) {
            link.tap()
        } else if app.staticTexts["Logs"].waitForExistence(timeout: 3) {
            app.staticTexts["Logs"].tap()
        } else {
            app.staticTexts["گزارش"].tap()
        }
    }

    private func acceptVPNAndDisclosure(app: XCUIApplication) {
        let accept = app.buttons["I understand"]
        if accept.waitForExistence(timeout: 4) {
            accept.tap()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "OK", "Allow Once", "Always Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 4) {
                button.tap()
            }
        }
    }
}
