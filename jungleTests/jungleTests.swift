import XCTest
import WebKit
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
    func testClosesSelectedTabAfterShowingClosingState() async {
        let store = BrowserStore()
        store.createTab()
        let closedTabID = store.selectedTabID

        store.closeSelectedTab()

        XCTAssertTrue(closedTabID.map(store.isClosingTab) ?? false)
        try? await Task.sleep(for: .milliseconds(250))
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

    @MainActor
    func testReturningPictureInPictureSelectsItsSourceWithoutStartingAnotherPictureInPictureSession() {
        let store = BrowserStore()
        let pictureInPictureSourceID = store.selectedTabID
        store.createTab()

        guard let pictureInPictureSourceID else {
            XCTFail("Expected an initial tab")
            return
        }

        store.restoreTabFromPictureInPicture(pictureInPictureSourceID)

        XCTAssertEqual(store.selectedTabID, pictureInPictureSourceID)
    }

    @MainActor
    func testMediaScriptRequiresPlaybackBeforeEnteringPictureInPicture() {
        let source = WebViewPool.mediaScript.source

        XCTAssertTrue(source.contains("activeVideo.paused"))
        XCTAssertFalse(source.contains("playingVideo() || document.querySelector('video')"))
        XCTAssertTrue(source.contains("isPictureInPictureActive"))
    }

    @MainActor
    func testDarkContentBackgroundIsNotWhite() {
        let background = WebViewPool.contentBackground(isDark: true)
        var white: CGFloat = 1

        background.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.5)
    }

    func testRecognizesHTTPAndHTTPSExternalURLs() {
        XCTAssertTrue(BrowserAddress.isWebURL(URL(string: "https://example.com") ?? BrowserAddress.home))
        XCTAssertTrue(BrowserAddress.isWebURL(URL(string: "http://example.com") ?? BrowserAddress.home))
        XCTAssertFalse(BrowserAddress.isWebURL(URL(string: "mailto:hello@example.com") ?? BrowserAddress.home))
        XCTAssertFalse(BrowserAddress.isWebURL(URL(fileURLWithPath: "/tmp/example")))
    }

    func testRecognizesHTTPAsAnInsecureConnection() {
        XCTAssertTrue(BrowserAddress.usesInsecureHTTP(URL(string: "http://example.com") ?? BrowserAddress.home))
        XCTAssertFalse(BrowserAddress.usesInsecureHTTP(URL(string: "https://example.com") ?? BrowserAddress.home))
    }

    func testRecognizesLocalDevelopmentURLs() {
        XCTAssertTrue(BrowserAddress.isLocalDevelopmentURL(URL(string: "http://localhost:3000") ?? BrowserAddress.home))
        XCTAssertTrue(BrowserAddress.isLocalDevelopmentURL(URL(string: "http://127.0.0.1:5173") ?? BrowserAddress.home))
        XCTAssertFalse(BrowserAddress.isLocalDevelopmentURL(URL(string: "https://example.com") ?? BrowserAddress.home))
    }

    func testDeveloperDiagnosticsDecodesPageMetrics() {
        let encoded = """
        {"pageURL":"http://localhost:3000/","requestCount":12,"repeatedRequestCount":3,"transferredBytes":2048,"javaScriptHeapBytes":1024,"documentNodeCount":42,"loadDurationMilliseconds":120}
        """

        let metrics = DeveloperDiagnostics.metrics(from: encoded)

        XCTAssertEqual(metrics?.pageURL.host, "localhost")
        XCTAssertEqual(metrics?.requestCount, 12)
        XCTAssertEqual(metrics?.repeatedRequestCount, 3)
        XCTAssertEqual(metrics?.javaScriptHeapBytes, 1024)
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

    func testBookmarkFolderDefaultsAreScopedToTheirProfile() {
        let profileID = UUID()
        let folders = BookmarkFolder.defaults(for: profileID)

        XCTAssertEqual(folders.map(\.profileID), [profileID, profileID])
        XCTAssertEqual(folders.filter(\.isQuickAccess).count, 1)
    }

    @MainActor
    func testCommandClickDestinationOnlyAcceptsWebLinks() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.com/article"))

        XCTAssertEqual(
            BrowserStore.commandClickDestination(
                navigationType: .linkActivated,
                modifierFlags: .command,
                shouldPerformDownload: false,
                requestURL: destination
            ),
            destination
        )
        XCTAssertNil(
            BrowserStore.commandClickDestination(
                navigationType: .linkActivated,
                modifierFlags: [],
                shouldPerformDownload: false,
                requestURL: destination
            )
        )
        XCTAssertNil(
            BrowserStore.commandClickDestination(
                navigationType: .linkActivated,
                modifierFlags: .command,
                shouldPerformDownload: true,
                requestURL: destination
            )
        )
    }

    @MainActor
    func testCommandClickOpensDestinationInNewSelectedTab() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let store = BrowserStore(persistence: persistence)
        let sourceTabID = try XCTUnwrap(store.selectedTabID)
        let sourceTab = try XCTUnwrap(store.selectedTab)
        let destination = try XCTUnwrap(URL(string: "https://example.com/article"))

        store.openLinkInNewTab(destination, from: sourceTabID)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.selectedTab?.address, destination)
        XCTAssertEqual(store.selectedTab?.profileID, sourceTab.profileID)
    }

    @MainActor
    func testBookmarkFoldersDoNotCrossProfileBoundaries() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let store = BrowserStore(persistence: persistence)
        let personalProfileID = store.activeProfileID
        let workProfileID = try XCTUnwrap(store.profiles.first(where: { $0.id != personalProfileID })?.id)

        store.createBookmarkFolder(named: "Personal only")
        XCTAssertTrue(store.visibleBookmarkFolders.contains(where: { $0.name == "Personal only" }))

        store.switchProfile(to: workProfileID)
        XCTAssertFalse(store.visibleBookmarkFolders.contains(where: { $0.name == "Personal only" }))

        store.createBookmarkFolder(named: "Work only")
        XCTAssertTrue(store.visibleBookmarkFolders.contains(where: { $0.name == "Work only" }))

        store.switchProfile(to: personalProfileID)
        XCTAssertFalse(store.visibleBookmarkFolders.contains(where: { $0.name == "Work only" }))
    }

    func testLinkPrewarmingOnlyAllowsSafeHTTPSDestinations() throws {
        let secure = try XCTUnwrap(URL(string: "https://example.com/article"))
        let insecure = try XCTUnwrap(URL(string: "http://example.com/article"))
        let credentialed = try XCTUnwrap(URL(string: "https://user:password@example.com/article"))

        XCTAssertTrue(LinkPrewarming.isEligibleDestination(secure))
        XCTAssertFalse(LinkPrewarming.isEligibleDestination(insecure))
        XCTAssertFalse(LinkPrewarming.isEligibleDestination(credentialed))
    }

    func testLinkPrewarmingOnlyWarmsOtherOrigins() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/current"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://example.com/next"))
        let sameOriginDefaultPort = try XCTUnwrap(URL(string: "https://example.com:443/next"))
        let subdomain = try XCTUnwrap(URL(string: "https://cdn.example.com/asset"))
        let alternatePort = try XCTUnwrap(URL(string: "https://example.com:8443/next"))

        XCTAssertFalse(LinkPrewarming.isCrossOrigin(sameOrigin, from: page))
        XCTAssertFalse(LinkPrewarming.isCrossOrigin(sameOriginDefaultPort, from: page))
        XCTAssertTrue(LinkPrewarming.isCrossOrigin(subdomain, from: page))
        XCTAssertTrue(LinkPrewarming.isCrossOrigin(alternatePort, from: page))
    }

    func testLinkPrewarmingScriptIsHoverDrivenAndBounded() {
        let source = LinkPrewarming.scriptSource

        XCTAssertTrue(source.contains("pointerover"))
        XCTAssertTrue(source.contains("pointerdown"))
        XCTAssertTrue(source.contains("MAXIMUM_PRECONNECTS = 2"))
        XCTAssertTrue(source.contains("MAXIMUM_DNS_PREFETCHES = 6"))
        XCTAssertTrue(source.contains("prefers-reduced-data"))
    }

    @MainActor
    func testLinkPrewarmingRunsInsideWebKitOnLinkIntent() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(LinkPrewarming.userScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<a id=\"destination\" href=\"https://developer.apple.com/documentation\">Documentation</a>",
            baseURL: try XCTUnwrap(URL(string: "https://example.com/current"))
        )

        await fulfillment(of: [navigation.finished], timeout: 5)
        let result = try await webView.evaluateJavaScript(
            """
            (function () {
                const anchor = document.getElementById('destination');
                anchor.dispatchEvent(new PointerEvent('pointerdown', {
                    bubbles: true,
                    button: 0,
                    pointerType: 'mouse'
                }));
                return Array.from(document.querySelectorAll('link[data-jungle-prewarm]'))
                    .map(function (link) { return link.rel + ':' + link.href; })
                    .sort()
                    .join('|');
            })();
            """,
            in: nil,
            contentWorld: .defaultClient
        ) as? String

        XCTAssertEqual(
            result,
            "dns-prefetch:https://developer.apple.com/|preconnect:https://developer.apple.com/"
        )
    }

    func testContentRuleCompilerTranslatesHostRulesAndExceptions() throws {
        let source = """
        ||ads.example.com^$script,third-party
        @@||ads.example.com^$domain=trusted.example
        /not-a-host-rule/
        """

        let json = ContentBlockerRuleCompiler.compile(source)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])

        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual((rules[0]["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertEqual((rules[0]["trigger"] as? [String: Any])?["resource-type"] as? [String], ["script"])
        XCTAssertEqual((rules[0]["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual((rules[1]["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
        XCTAssertEqual((rules[1]["trigger"] as? [String: Any])?["if-domain"] as? [String], ["trusted.example"])
    }

    @MainActor
    func testGeneratedContentRulesCompileInWebKit() async throws {
        let source = ContentBlockerRuleCompiler.compile("||tracker.example^$third-party,script")
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "jungle.tests.\(UUID().uuidString)"
        defer { Task { try? await store.removeContentRuleList(forIdentifier: identifier) } }

        let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source)
        let list = try XCTUnwrap(compiled)

        XCTAssertEqual(list.identifier, identifier)
    }

    func testContentBlockingUsesFallbackWhenAnyPrimarySourceIsUnavailable() {
        XCTAssertTrue(ContentBlockingSourcePolicy.shouldUseFallback(primarySourcesAreUsable: [true, false]))
        XCTAssertFalse(ContentBlockingSourcePolicy.shouldUseFallback(primarySourcesAreUsable: [true, true]))
    }
}

@MainActor
private final class NavigationCompletion: NSObject, WKNavigationDelegate {
    let finished = XCTestExpectation(description: "Web view finished loading")

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
}
