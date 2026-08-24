import XCTest

final class JungleUITests: XCTestCase {
    @MainActor
    func testLaunchesWorkspace() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Jungle"].waitForExistence(timeout: 3))
    }
}
