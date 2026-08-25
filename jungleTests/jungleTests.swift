import XCTest
@testable import jungle

final class JungleTests: XCTestCase {
    @MainActor
    func testSwitchProfileByShortcutNumber() {
        let store = BrowserStore()

        store.switchProfile(number: 2)

        XCTAssertEqual(store.activeProfile.name, "Work")
        XCTAssertFalse(store.visibleTabs.isEmpty)
    }

    @MainActor
    func testMovesTabsHorizontally() {
        let store = BrowserStore()
        store.createTab()
        let tabs = store.visibleTabs
        let selectedIndex = tabs.firstIndex(where: { $0.id == store.selectedTabID }) ?? 0
        let expectedTabID = tabs[(selectedIndex - 1 + tabs.count) % tabs.count].id

        store.moveSelectedTabHorizontally(by: -1)

        XCTAssertEqual(store.selectedTabID, expectedTabID)
        XCTAssertNotNil(store.tabPreviewID)
    }

    @MainActor
    func testIdleTabsExcludeSelectedPinnedAndRecentTabs() {
        let profileID = UUID()
        let cutoff = Date.now
        let idle = BrowserTab(profileID: profileID, lastActivatedAt: cutoff.addingTimeInterval(-60))
        let selected = BrowserTab(profileID: profileID, lastActivatedAt: cutoff.addingTimeInterval(-60))
        let pinned = BrowserTab(profileID: profileID, lastActivatedAt: cutoff.addingTimeInterval(-60), isPinned: true)
        let recent = BrowserTab(profileID: profileID, lastActivatedAt: cutoff.addingTimeInterval(60))

        let candidates = BrowserStore.idleTabs(in: [idle, selected, pinned, recent], cutoff: cutoff, selectedTabID: selected.id)

        XCTAssertEqual(candidates.map(\.id), [idle.id])
    }

    @MainActor
    func testClosesSelectedTab() {
        let store = BrowserStore()
        store.createTab()
        let closedTabID = store.selectedTabID

        store.closeSelectedTab()

        XCTAssertFalse(store.tabs.contains(where: { $0.id == closedTabID }))
        XCTAssertNotEqual(store.selectedTabID, closedTabID)
    }

    @MainActor
    func testOpeningBookmarkCreatesAndSelectsNewTab() {
        let store = BrowserStore()
        let previousTabID = store.selectedTabID
        let previousTabCount = store.tabs.count
        let bookmark = BrowserBookmark(
            title: "Example",
            address: URL(string: "https://example.com") ?? BrowserAddress.home
        )
        defer {
            store.closeSelectedTab()
            if let previousTabID {
                store.select(previousTabID)
            }
        }

        store.openBookmark(bookmark)

        XCTAssertEqual(store.tabs.count, previousTabCount + 1)
        XCTAssertNotEqual(store.selectedTabID, previousTabID)
        XCTAssertEqual(store.selectedTab?.address, bookmark.address)
        XCTAssertEqual(store.selectedTab?.title, bookmark.title)
    }

    @MainActor
    func testCyclesTabsInVisualOrderWhileControlIsHeld() {
        let store = BrowserStore()
        store.createTab()
        let tabs = store.visibleTabs
        let selectedIndex = tabs.firstIndex(where: { $0.id == store.selectedTabID }) ?? 0
        let expectedTabID = tabs[(selectedIndex + 3) % tabs.count].id

        for _ in 0..<3 {
            store.moveSelectedTabHorizontally(by: 1, keepsPreviewVisible: true)
        }

        XCTAssertEqual(store.selectedTabID, expectedTabID)
        XCTAssertEqual(store.tabPreviewID, expectedTabID)
    }

    @MainActor
    func testNewTabCycleReturnsToTabSelectedBeforePreviousCycle() {
        let store = BrowserStore()
        store.createTab()
        let previousTabID = store.selectedTabID
        store.createTab()

        store.selectPreviouslySelectedTab(keepsPreviewVisible: true)
        store.moveSelectedTabHorizontally(by: 1, keepsPreviewVisible: true)
        store.selectPreviouslySelectedTab(keepsPreviewVisible: true)

        XCTAssertEqual(store.selectedTabID, previousTabID)
        XCTAssertEqual(store.tabPreviewID, previousTabID)
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
