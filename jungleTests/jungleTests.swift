import XCTest
@testable import jungle

final class JungleTests: XCTestCase {
    @MainActor
    func testSwitchProfileByShortcutNumber() {
        let store = BrowserStore()

        store.switchProfile(number: 2)

        XCTAssertEqual(store.activeProfile.name, "Work")
        XCTAssertEqual(store.visibleTabs.count, 1)
    }

    @MainActor
    func testMovesTabsHorizontally() {
        let store = BrowserStore()
        let firstTabID = store.selectedTabID
        store.createTab()

        store.moveSelectedTabHorizontally(by: -1)

        XCTAssertEqual(store.selectedTabID, firstTabID)
        XCTAssertNotNil(store.tabPreviewID)
    }

    func testResolveUsesHTTPSForHostnames() {
        XCTAssertEqual(BrowserAddress.resolve("example.com")?.absoluteString, "https://example.com")
    }

    func testResolveUsesSearchForPlainText() {
        XCTAssertEqual(BrowserAddress.resolve("minimal browser")?.host, "www.google.com")
    }

    func testResolveUsesConfiguredSearchEngine() {
        XCTAssertEqual(
            BrowserAddress.resolve("minimal browser", using: .duckDuckGo)?.host,
            "duckduckgo.com"
        )
    }

    func testResolveRejectsBlankAddress() {
        XCTAssertNil(BrowserAddress.resolve("  "))
    }
}
