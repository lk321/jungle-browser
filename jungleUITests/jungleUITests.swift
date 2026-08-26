import XCTest

final class JungleUITests: XCTestCase {
    @MainActor
    func testLaunchesWorkspace() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Toggle sidebar"].waitForExistence(timeout: 3))
    }
}
