import XCTest
#if canImport(StoreKitTest)
import StoreKitTest
#endif

final class AzadiTunnelLegalTests: XCTestCase {
    private let bundleID = "com.polamgh.ali.AzadiTunnel"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication(bundleIdentifier: bundleID).terminate()
    }

    func testDisclaimerBlocksUntilAccepted() throws {
        let app = launchApp(extraArgs: ["-UITestResetDisclaimer"])
        let connect = app.buttons["connectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))

        connect.tap()
        let accept = app.buttons["disclaimerAcceptButton"]
        XCTAssertTrue(accept.waitForExistence(timeout: 8), "Disclaimer should appear on first connect")

        app.buttons["disclaimerCancelButton"].tap()
        XCTAssertTrue(accept.waitForExistence(timeout: 4) == false || !app.buttons["disclaimerAcceptButton"].isHittable)

        connect.tap()
        XCTAssertTrue(app.buttons["disclaimerAcceptButton"].waitForExistence(timeout: 8))

        accept.tap()
        XCTAssertFalse(app.buttons["disclaimerAcceptButton"].waitForExistence(timeout: 3))

        connect.tap()
        XCTAssertFalse(app.buttons["disclaimerAcceptButton"].waitForExistence(timeout: 3), "Disclaimer should not reappear")
    }

    func testStoreKitLocalProductsLoad() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("StoreKit local configuration test is simulator-only")
        #endif
        #if canImport(StoreKitTest)
        let session = try SKTestSession(configurationFileNamed: "Configuration")
        session.disableDialogs = true
        session.clearTransactions()
        #endif

        let app = launchApp(extraArgs: ["-UITestClearLogs", "-UITestLoadIAPProducts"], forceBootstrap: false)
        let settingsTab = app.tabBars.buttons["settingsTabBar"]
        let fallbackTab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(
            settingsTab.waitForExistence(timeout: 30) || fallbackTab.waitForExistence(timeout: 5),
            "Settings tab should appear"
        )
        if settingsTab.exists {
            settingsTab.tap()
        } else {
            fallbackTab.tap()
        }

        openSettingsRow(app, identifier: "supportAzadiTunnelLink", title: "Support AzadiTunnel")

        let smallTip = app.buttons["iap_product_azaditunnel.tip.small"]
        XCTAssertTrue(
            smallTip.waitForExistence(timeout: 20),
            "StoreKit local config should expose tip product with localized price"
        )
        XCTAssertTrue(app.buttons["iap_product_azaditunnel.support.monthly"].waitForExistence(timeout: 5))
    }

    func testLegalAndPrivacyPagesOpen() throws {
        let app = launchApp(extraArgs: [])
        let settingsTab = app.tabBars.buttons["settingsTabBar"]
        let fallbackTab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(
            settingsTab.waitForExistence(timeout: 30) || fallbackTab.waitForExistence(timeout: 5),
            "Settings tab should appear"
        )
        if settingsTab.exists {
            settingsTab.tap()
        } else {
            fallbackTab.tap()
        }

        openSettingsRow(app, identifier: "legalOpenSourceLink", title: "Legal & Open Source")
        XCTAssertTrue(
            app.otherElements["legalOpenSourceScreen"].waitForExistence(timeout: 8)
                || app.navigationBars["Legal & Open Source"].waitForExistence(timeout: 8)
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()

        openSettingsRow(app, identifier: "privacyNoticeLink", title: "Privacy Notice")
        XCTAssertTrue(
            app.otherElements["privacyNoticeScreen"].waitForExistence(timeout: 8)
                || app.navigationBars["Privacy Notice"].waitForExistence(timeout: 8)
        )
    }

    private func openSettingsRow(_ app: XCUIApplication, identifier: String, title: String) {
        let link = app.buttons[identifier]
        if link.waitForExistence(timeout: 3) {
            link.tap()
            return
        }
        for _ in 0..<4 {
            let text = app.staticTexts[title]
            if text.waitForExistence(timeout: 2) {
                text.tap()
                return
            }
            app.swipeUp()
        }
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let cell = app.cells.containing(predicate).firstMatch
        if cell.waitForExistence(timeout: 3) {
            cell.tap()
        }
    }

    private func launchApp(extraArgs: [String], forceBootstrap: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-UITestMode", "-UITestSkipSplash"]
        if forceBootstrap {
            args.append("-UITestForceBootstrap")
        }
        args.append(contentsOf: extraArgs)
        app.launchArguments = args
        app.launch()
        return app
    }
}
