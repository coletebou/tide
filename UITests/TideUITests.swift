import XCTest

final class TideUITests: XCTestCase {
    func testLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetWorkspace"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
