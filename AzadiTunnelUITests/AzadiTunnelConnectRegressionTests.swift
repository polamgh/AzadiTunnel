import XCTest

final class AzadiTunnelConnectRegressionTests: XCTestCase {
    private let generate204URL = URL(string: "https://www.google.com/generate_204")!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication(bundleIdentifier: "com.polamgh.ali.AzadiTunnel").terminate()
    }

    func testHomeConnectRealInternetAndTraffic() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "-UITestForceBootstrap"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))

        let connect = app.buttons["connectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))
        let enabled = NSPredicate(format: "isEnabled == true")
        wait(for: [expectation(for: enabled, evaluatedWith: connect, handler: nil)], timeout: 60)
        connect.tap()
        acceptDisclosureIfNeeded(app: app)
        handleVPNPermissionAlertIfNeeded()
        handleVPNPermissionAlertIfNeeded()

        let status = app.staticTexts["statusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        wait(for: [expectation(for: vpnConnectedPredicate(), evaluatedWith: status, handler: nil)], timeout: 180)

        let httpExpectation = expectation(description: "generate_204")
        var statusCode = 0
        URLSession.shared.dataTask(with: generate204URL) { _, response, error in
            defer { httpExpectation.fulfill() }
            if let error {
                XCTFail("HTTP request failed: \(error)")
                return
            }
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        }.resume()
        wait(for: [httpExpectation], timeout: 60)
        XCTAssertEqual(statusCode, 204)

        scrollDashboardToStats(app)
        let totalDown = trafficValueElement(app, identifier: "totalDownloadLabel")
        XCTAssertTrue(totalDown.waitForExistence(timeout: 20))
        let totalBefore = totalDown.label
        sleep(12)
        let totalAfter = totalDown.label
        XCTAssertTrue(
            totalAfter != totalBefore || (!totalAfter.hasPrefix("0 ") && totalAfter != "0 KB"),
            "Expected traffic on dashboard (before=\(totalBefore) after=\(totalAfter))"
        )

        connect.tap()
        wait(for: [expectation(for: vpnDisconnectedPredicate(), evaluatedWith: status, handler: nil)], timeout: 120)
    }

    private func handleVPNPermissionAlertIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "OK", "Allow Once", "Always Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 3) {
                button.tap()
            }
        }
        let allowPredicate = NSPredicate(format: "label CONTAINS[c] 'Allow'")
        let allowMatch = springboard.buttons.containing(allowPredicate).firstMatch
        if allowMatch.waitForExistence(timeout: 3) {
            allowMatch.tap()
        }
    }

    private func vpnConnectedPredicate() -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "label CONTAINS[c] %@", "Connected"),
            NSPredicate(format: "label CONTAINS[c] %@", "متصل")
        ])
    }

    private func vpnDisconnectedPredicate() -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "label CONTAINS[c] %@", "Disconnected"),
            NSPredicate(format: "label CONTAINS[c] %@", "قطع")
        ])
    }

    private func trafficValueElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let query = app.staticTexts.matching(identifier: identifier)
        for index in 0..<4 {
            let element = query.element(boundBy: index)
            guard element.exists else { break }
            if element.label.contains("KB") || element.label.contains("MB") || element.label.contains("GB")
                || element.label.contains("B/s") || element.label.contains(" B") {
                return element
            }
        }
        return query.element(boundBy: 0)
    }

    private func scrollDashboardToStats(_ app: XCUIApplication) {
        for _ in 0..<4 {
            app.swipeUp()
            if app.staticTexts["totalDownloadLabel"].exists { return }
        }
    }

    private func acceptDisclosureIfNeeded(app: XCUIApplication) {
        let accept = app.buttons["disclaimerAcceptButton"]
        if accept.waitForExistence(timeout: 4) {
            accept.tap()
            return
        }
        let legacy = app.buttons["I Understand and Agree"]
        if legacy.waitForExistence(timeout: 2) {
            legacy.tap()
        }
    }

}
