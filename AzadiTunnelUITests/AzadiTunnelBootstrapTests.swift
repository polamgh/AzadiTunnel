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
}
