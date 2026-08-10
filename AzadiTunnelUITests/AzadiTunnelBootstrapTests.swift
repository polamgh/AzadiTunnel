import XCTest

/// Fast sanity check that XCTest runner bootstraps on a physical device.
final class AzadiTunnelBootstrapTests: XCTestCase {
    func test00_RunnerSmokeWithoutLaunch() {
        XCTAssertTrue(true, "XCTest runner bootstrap sanity check")
    }

    func test01_RunnerLaunchesHostApp() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.terminate()
    }

    func test02_PrimaryVoiceOverElementsHaveReadableLabels() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode"]
        app.launch()

        let connect = app.buttons["connectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        XCTAssertFalse(connect.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let status = app.staticTexts["statusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertFalse(status.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let region = app.buttons["dashboardRegionMenu"]
        XCTAssertTrue(region.waitForExistence(timeout: 10))
        XCTAssertFalse(region.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        app.terminate()
    }
}
