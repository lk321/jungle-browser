import XCTest
import WebKit
@testable import jungle

final class JungleTests: XCTestCase {
    /// Never the shared store: these tests used to read and rewrite the real browsing database.
    @MainActor
    private func makeStore() -> BrowserStore {
        BrowserStore(persistence: try! BrowserPersistence(testingInMemory: true))
    }

    @MainActor
    func testSwitchProfileByShortcutNumber() {
        let store = makeStore()

        store.switchProfile(number: 2)

        XCTAssertEqual(store.activeProfile.name, "Work")
        XCTAssertFalse(store.visibleTabs.isEmpty)
    }

    @MainActor
    func testMovesTabsHorizontally() {
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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
    func testPictureInPictureTrackingFollowsPresentationEventsAndTabRemoval() {
        let store = makeStore()
        guard let sourceID = store.selectedTabID else {
            XCTFail("Expected an initial tab")
            return
        }
        store.createTab()
        let otherTabID = store.selectedTabID

        store.pictureInPictureDidChange(isActive: true, tabID: sourceID)

        XCTAssertEqual(store.pictureInPictureTabID, sourceID)
        XCTAssertEqual(store.pictureInPictureHoldTabID, sourceID)
        XCTAssertEqual(store.selectedTabID, otherTabID, "Floating video must not steal the selection")

        store.pictureInPictureDidChange(isActive: false, tabID: sourceID)

        XCTAssertNil(store.pictureInPictureTabID)
        XCTAssertEqual(store.selectedTabID, sourceID, "Returning inline shows the video's own tab")

        store.pictureInPictureDidChange(isActive: true, tabID: sourceID)
        store.close(sourceID)

        XCTAssertNil(store.pictureInPictureHoldTabID, "A closed tab cannot hold the floating window")
    }

    @MainActor
    func testMediaScriptRequiresPlaybackBeforeEnteringPictureInPicture() {
        let source = WebViewPool.mediaScript.source

        XCTAssertTrue(source.contains("activeVideo.paused"))
        XCTAssertFalse(source.contains("playingVideo() || document.querySelector('video')"))
        XCTAssertTrue(source.contains("isPictureInPictureActive"))
        XCTAssertTrue(source.contains("webkitpresentationmodechanged"), "Tracking is event driven, not polled")
    }

    @MainActor
    func testYouTubeAdBlockingOnlyRunsOnYouTubeAndSkipsAdsWithoutPolling() {
        let source = YouTubeAdBlocking.scriptSource

        XCTAssertTrue(source.contains("youtube(-nocookie)?"), "Must not touch other sites")
        XCTAssertTrue(source.contains("ad-showing"), "Only seeks while the player marks an ad")
        XCTAssertTrue(source.contains("video.currentTime = video.duration"))
        XCTAssertFalse(source.contains("setInterval"), "No polling timer")
        XCTAssertFalse(source.contains("MutationObserver"), "No page-wide observer")
        XCTAssertTrue(YouTubeAdBlocking.hiddenSelectors.contains("#player-ads"))
    }

    @MainActor
    func testDarkContentBackgroundIsNotWhite() {
        let background = WebViewPool.contentBackground(isDark: true)
        var white: CGFloat = 1

        background.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.5)
    }

    func testExplicitAppearanceControlsInitialWebContentColor() {
        XCTAssertTrue(BrowserAppearance.dark.usesDarkContent(systemIsDark: false))
        XCTAssertFalse(BrowserAppearance.light.usesDarkContent(systemIsDark: true))
        XCTAssertTrue(BrowserAppearance.system.usesDarkContent(systemIsDark: true))
        XCTAssertFalse(BrowserAppearance.system.usesDarkContent(systemIsDark: false))
    }

    @MainActor
    func testInitialWebContentIsCoveredUntilItFinishesLoading() throws {
        let store = makeStore()
        let tabID = try XCTUnwrap(store.selectedTabID)

        XCTAssertFalse(store.selectedTabInitialContentIsReady)

        store.didCommitNavigation(for: tabID, url: store.selectedTab?.address)

        XCTAssertFalse(store.selectedTabInitialContentIsReady)

        store.didFinishNavigation(for: tabID, title: "Example", url: store.selectedTab?.address)

        XCTAssertTrue(store.selectedTabInitialContentIsReady)

        store.didTerminateWebContent(for: tabID)

        XCTAssertFalse(store.selectedTabInitialContentIsReady)
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
    func testMovesOpenTabsInSidebarOrderWithoutChangingSelection() throws {
        let store = makeStore()
        let firstTabID = try XCTUnwrap(store.selectedTabID)
        store.createTab()
        let secondTabID = try XCTUnwrap(store.selectedTabID)
        store.createTab()
        let thirdTabID = try XCTUnwrap(store.selectedTabID)

        store.moveTab(thirdTabID, before: firstTabID)

        XCTAssertEqual(store.visibleTabs.map(\.id), [thirdTabID, firstTabID, secondTabID])
        XCTAssertEqual(store.selectedTabID, thirdTabID)
    }

    @MainActor
    func testSavesOpenTabToQuickAccessWithoutCreatingAnotherTab() throws {
        let store = makeStore()
        let sourceTabID = try XCTUnwrap(store.selectedTabID)
        let destination = try XCTUnwrap(URL(string: "https://example.com/quick-access"))
        store.openLinkInNewTab(destination, from: sourceTabID)
        let tabID = try XCTUnwrap(store.selectedTabID)
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let initialTabCount = store.tabs.count

        XCTAssertTrue(store.saveTab(tabID, to: quickAccess.id))

        XCTAssertEqual(store.tabs.count, initialTabCount)
        XCTAssertEqual(
            store.visibleBookmarkFolders.first(where: { $0.id == quickAccess.id })?.bookmarks.last?.address,
            store.selectedTab?.address
        )
        XCTAssertFalse(store.saveTab(tabID, to: quickAccess.id), "A drop should not create duplicate saved pages")
    }

    @MainActor
    func testMovesAndRemovesBookmarkAcrossFolders() throws {
        let store = makeStore()
        let sourceTabID = try XCTUnwrap(store.selectedTabID)
        let destination = try XCTUnwrap(URL(string: "https://example.com/reading-list"))
        store.openLinkInNewTab(destination, from: sourceTabID)
        let tabID = try XCTUnwrap(store.selectedTabID)
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let readingList = try XCTUnwrap(store.visibleBookmarkFolders.first(where: { !$0.isQuickAccess }))
        XCTAssertTrue(store.saveTab(tabID, to: readingList.id))
        let bookmarkID = try XCTUnwrap(
            store.visibleBookmarkFolders.first(where: { $0.id == readingList.id })?.bookmarks.last?.id
        )

        store.moveBookmark(bookmarkID, from: readingList.id, to: quickAccess.id)

        XCTAssertFalse(store.visibleBookmarkFolders.first(where: { $0.id == readingList.id })?.bookmarks.contains(where: { $0.id == bookmarkID }) ?? true)
        XCTAssertTrue(store.visibleBookmarkFolders.first(where: { $0.id == quickAccess.id })?.bookmarks.contains(where: { $0.id == bookmarkID }) ?? false)

        store.deleteBookmark(bookmarkID, from: quickAccess.id)

        XCTAssertFalse(store.visibleBookmarkFolders.flatMap(\.bookmarks).contains(where: { $0.id == bookmarkID }))
    }

    @MainActor
    func testReordersQuickAccessBookmarks() throws {
        let store = makeStore()
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let firstBookmarkID = try XCTUnwrap(quickAccess.bookmarks.first?.id)
        let lastBookmarkID = try XCTUnwrap(quickAccess.bookmarks.last?.id)

        store.moveBookmark(lastBookmarkID, from: quickAccess.id, to: quickAccess.id, before: firstBookmarkID)

        XCTAssertEqual(
            store.visibleBookmarkFolders.first(where: { $0.id == quickAccess.id })?.bookmarks.first?.id,
            lastBookmarkID
        )
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

    @MainActor
    func testYouTubeAdSkippingEndsAnUnskippableAdInsideWebKit() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(YouTubeAdBlocking.userScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            """
            <div id="movie_player" class="html5-video-player ad-showing"><video id="player-video"></video></div>
            <div id="player-ads">promo</div>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=test"))
        )

        await fulfillment(of: [navigation.finished], timeout: 5)
        let result = try await webView.evaluateJavaScript(
            """
            (function () {
                const player = document.getElementById('movie_player');
                const video = document.getElementById('player-video');
                Object.defineProperty(video, 'duration', { value: 30, configurable: true });
                // A video element with no media ignores seeks, so record the one we make.
                let seekedTo = null;
                Object.defineProperty(video, 'currentTime', {
                    get: function () { return seekedTo === null ? 0 : seekedTo; },
                    set: function (value) { seekedTo = value; },
                    configurable: true
                });
                video.dispatchEvent(new Event('timeupdate', { bubbles: true }));
                const skipped = seekedTo === 30 && video.muted;

                // The real video keeps its sound once the ad is gone.
                player.classList.remove('ad-showing');
                video.dispatchEvent(new Event('timeupdate', { bubbles: true }));

                const adsHidden = getComputedStyle(document.getElementById('player-ads')).display === 'none';
                return [skipped, !video.muted, adsHidden].join(',');
            })();
            """,
            in: nil,
            contentWorld: .defaultClient
        ) as? String

        XCTAssertEqual(result, "true,true,true")
    }

    /// The scripts are worthless if the pool stops installing them on new tabs.
    @MainActor
    func testPooledWebViewsCarryBothYouTubeAdScripts() async throws {
        let profile = BrowserProfile(name: "Ads", symbol: "person", tint: .green)
        let tab = BrowserTab(profileID: profile.id)
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        let scripts = webView.configuration.userContentController.userScripts

        XCTAssertTrue(scripts.contains { $0.source == YouTubeAdBlocking.scriptSource })
        XCTAssertTrue(scripts.contains { $0.source == YouTubeAdBlocking.playerScriptSource })
        XCTAssertTrue(scripts.contains { $0.source == WebViewPool.mediaScript.source })

        WebViewPool.shared.discard(tab.id)
        try? await WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID)
    }

    @MainActor
    func testYouTubeAdPlacementsAreStrippedFromThePlayerResponse() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(YouTubeAdBlocking.playerScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<title>watch</title>",
            baseURL: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=test"))
        )

        await fulfillment(of: [navigation.finished], timeout: 5)
        let result = try await webView.evaluateJavaScript(
            """
            (function () {
                window.ytInitialPlayerResponse = {
                    adPlacements: [{ kind: 'AD_PLACEMENT_KIND_START' }],
                    playerAds: [1],
                    videoDetails: { title: 'kept' }
                };
                const inline = window.ytInitialPlayerResponse;
                const fetched = JSON.parse('{"adPlacements":[1],"streamingData":{"kept":true}}');
                return [
                    inline.adPlacements === undefined,
                    inline.playerAds === undefined,
                    inline.videoDetails.title === 'kept',
                    fetched.adPlacements === undefined,
                    fetched.streamingData.kept === true
                ].join(',');
            })();
            """,
            in: nil,
            contentWorld: .page
        ) as? String

        XCTAssertEqual(result, "true,true,true,true,true")
    }

    @MainActor
    func testYouTubeAdPlacementStrippingLeavesOtherSitesAlone() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(YouTubeAdBlocking.playerScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<title>watch</title>",
            baseURL: try XCTUnwrap(URL(string: "https://example.com/watch"))
        )

        await fulfillment(of: [navigation.finished], timeout: 5)
        let untouched = try await webView.evaluateJavaScript(
            "JSON.parse('{\"adPlacements\":[1]}').adPlacements !== undefined",
            in: nil,
            contentWorld: .page
        ) as? Bool

        XCTAssertEqual(untouched, true)
    }

    @MainActor
    func testYouTubeAdSkippingLeavesOtherSitesAlone() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(YouTubeAdBlocking.userScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<div id=\"movie_player\" class=\"ad-showing\"><video id=\"player-video\"></video></div>",
            baseURL: try XCTUnwrap(URL(string: "https://example.com/watch"))
        )

        await fulfillment(of: [navigation.finished], timeout: 5)
        let untouched = try await webView.evaluateJavaScript(
            """
            (function () {
                const video = document.getElementById('player-video');
                Object.defineProperty(video, 'duration', { value: 30, configurable: true });
                video.dispatchEvent(new Event('timeupdate', { bubbles: true }));
                return video.currentTime === 0 && !video.muted && !document.getElementById('jungle-ad-style');
            })();
            """,
            in: nil,
            contentWorld: .defaultClient
        ) as? Bool

        XCTAssertEqual(untouched, true)
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
