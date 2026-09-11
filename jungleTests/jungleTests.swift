import XCTest
import WebKit
@testable import jungle

final class JungleTests: XCTestCase {
    /// Never the shared store: these tests used to read and rewrite the real browsing database.
    @MainActor
    private func makeStore() -> BrowserStore {
        BrowserStore(persistence: try! BrowserPersistence(testingInMemory: true))
    }

    /// A capture prompt covers one device or both, so a pair of stored answers has to settle
    /// the combined request: any block denies, all allows grant, anything else still asks.
    @MainActor
    func testSitePermissionsCombineStoredDeviceAnswers() {
        let origin = "https://tests.jungle.invalid"
        defer { SitePermissions.forget(origin) }

        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]))

        SitePermissions.remember(true, for: origin, kinds: [.camera])
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera]), true)
        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]))

        SitePermissions.remember(true, for: origin, kinds: [.microphone])
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]), true)

        SitePermissions.remember(false, for: origin, kinds: [.microphone])
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]), false)
        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.notifications]))
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
    func testSameDocumentNavigationRewritesTheTabAddress() throws {
        let store = makeStore()
        let tabID = try XCTUnwrap(store.selectedTabID)
        let watched = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc"))

        // A pushState navigation never starts or finishes: the address arrives on its own.
        store.didCommitNavigation(for: tabID, url: watched)

        XCTAssertEqual(store.selectedTab?.address, watched)
        XCTAssertEqual(store.selectedTabAddressText, watched.absoluteString)
    }

    @MainActor
    func testMutingATabSurvivesUntilTheTabIsUnmutedOrClosed() throws {
        let store = makeStore()
        let tabID = try XCTUnwrap(store.selectedTabID)

        XCTAssertFalse(store.isMuted(tabID))
        store.toggleMuted(tabID)
        XCTAssertTrue(store.isMuted(tabID))

        // A finished navigation injects a fresh script that starts unmuted, so the tab has to
        // be told again — the flag surviving in Swift is not the same as the page being silent.
        WebViewPool.shared.forgetAppliedMuteState(for: tabID)
        store.didStartNavigation(for: tabID)
        store.didFinishNavigation(for: tabID, title: "Video", url: store.selectedTab?.address)
        XCTAssertTrue(store.isMuted(tabID))
        XCTAssertEqual(WebViewPool.shared.appliedMuteStates[tabID], true)

        store.toggleMuted(tabID)
        XCTAssertFalse(store.isMuted(tabID))
        XCTAssertEqual(WebViewPool.shared.appliedMuteStates[tabID], false)
    }

    @MainActor
    func testAnUnreachableAddressStillGetsItsMuteBack() throws {
        let store = makeStore()
        let tabID = try XCTUnwrap(store.selectedTabID)
        store.toggleMuted(tabID)

        // `about:` and friends fail the web-URL guard further down didFinishNavigation.
        WebViewPool.shared.forgetAppliedMuteState(for: tabID)
        store.didFinishNavigation(for: tabID, title: "", url: URL(string: "about:blank"))

        XCTAssertEqual(WebViewPool.shared.appliedMuteStates[tabID], true)
    }

    @MainActor
    func testMediaScriptReportsAudioWithoutPollingAndReappliesMuteToNewElements() {
        let source = WebViewPool.mediaScript.source

        XCTAssertTrue(source.contains("audioDidChange"))
        XCTAssertTrue(source.contains("setMuted"))
        XCTAssertFalse(source.contains("setInterval"), "Audio state is event driven, not polled")
        XCTAssertTrue(source.contains("'volumechange'"), "A page muting itself has to be reported")
        XCTAssertTrue(source.contains("'loadstart'"), "A swapped-in element has to inherit the mute")
        XCTAssertFalse(source.contains("!media.muted && media.volume"), "A muted tab keeps its speaker control")
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

    func testChromeDeclarativeRulesOnlyTranslateSafeStaticBlockFilters() {
        let compatibleRule = ChromeDeclarativeNetRequestRule(
            action: .init(type: "block"),
            condition: .init(
                urlFilter: "||example.com^",
                regexFilter: nil,
                resourceTypes: ["script"],
                excludedResourceTypes: nil,
                domains: nil,
                excludedDomains: nil
            )
        )
        let scriptRule = ChromeDeclarativeNetRequestRule(
            action: .init(type: "redirect"),
            condition: .init(
                urlFilter: "||example.com^",
                regexFilter: nil,
                resourceTypes: nil,
                excludedResourceTypes: nil,
                domains: nil,
                excludedDomains: nil
            )
        )
        let arbitraryRegexRule = ChromeDeclarativeNetRequestRule(
            action: .init(type: "block"),
            condition: .init(
                urlFilter: nil,
                regexFilter: ".*",
                resourceTypes: nil,
                excludedResourceTypes: nil,
                domains: nil,
                excludedDomains: nil
            )
        )

        let compilation = ChromeDeclarativeRuleCompiler.compile([compatibleRule, scriptRule, arbitraryRegexRule])

        XCTAssertEqual(compilation.ruleCount, 1)
        XCTAssertEqual(compilation.unsupportedRuleCount, 2)
        XCTAssertTrue(compilation.source.contains("example\\\\.com"))
    }

    func testDeveloperDiagnosticsDecodesPageMetrics() {
        let encoded = """
        {"type":"metrics","pageURL":"http://localhost:3000/","requestCount":12,"repeatedRequestCount":3,"transferredBytes":2048,"javaScriptHeapBytes":1024,"documentNodeCount":42,"loadDurationMilliseconds":120}
        """

        guard case .metrics(let metrics)? = DeveloperDiagnostics.message(from: encoded) else {
            return XCTFail("expected metrics")
        }

        XCTAssertEqual(metrics.pageURL.host, "localhost")
        XCTAssertEqual(metrics.requestCount, 12)
        XCTAssertEqual(metrics.repeatedRequestCount, 3)
        XCTAssertEqual(metrics.javaScriptHeapBytes, 1024)
    }

    func testDeveloperDiagnosticsDecodesFirstContentfulPaint() {
        guard case .firstContentfulPaint? = DeveloperDiagnostics.message(from: #"{"type":"paint"}"#) else {
            return XCTFail("expected paint")
        }
    }

    func testDeveloperDiagnosticsRejectsUnknownAndMalformedMessages() {
        XCTAssertNil(DeveloperDiagnostics.message(from: #"{"type":"something-else"}"#))
        XCTAssertNil(DeveloperDiagnostics.message(from: #"{"pageURL":"https://example.com"}"#))
        XCTAssertNil(DeveloperDiagnostics.message(from: "not json"))
        // A metrics envelope missing its required fields must not decode as an empty page.
        XCTAssertNil(DeveloperDiagnostics.message(from: #"{"type":"metrics"}"#))
    }

    @MainActor
    func testFirstContentfulPaintRevealsContentBeforeLoadFinishes() {
        let store = makeStore()
        guard let tabID = store.selectedTabID else { return XCTFail("no selected tab") }

        store.didStartNavigation(for: tabID)
        XCTAssertFalse(store.selectedTabInitialContentIsReady)

        store.didPaintFirstContent(for: tabID)

        XCTAssertTrue(store.selectedTabInitialContentIsReady)
        XCTAssertTrue(store.isSelectedTabLoading, "the page is revealed while it is still loading")
    }

    @MainActor
    func testFirstContentfulPaintIgnoresUnknownTabs() {
        let store = makeStore()

        store.didPaintFirstContent(for: UUID())

        XCTAssertTrue(store.initialContentReadyTabIDs.isEmpty)
    }

    @MainActor
    func testTabSleepIntervalDefaultsToFiveMinutes() throws {
        let settings = BrowserSettings(persistence: try BrowserPersistence(testingInMemory: true))

        XCTAssertEqual(settings.tabSleepInterval, 300)
        XCTAssertEqual(BrowserSettings.defaultTabSleepInterval, 300)
    }

    func testDeveloperDiagnosticsMapsStackSignalsToTechnologies() {
        let encoded = """
        {"type":"metrics","pageURL":"http://localhost:3000/","requestCount":4,"repeatedRequestCount":0,"transferredBytes":512,"javaScriptHeapBytes":null,"documentNodeCount":10,"loadDurationMilliseconds":null,"technologies":["react.root","next.data","react.hook","vite"]}
        """

        guard case .metrics(let metrics)? = DeveloperDiagnostics.message(from: encoded) else {
            return XCTFail("The payload did not decode as metrics")
        }
        let technologies: [DetectedTechnology]? = metrics.technologies

        // Next.js outranks React, and React is listed once even though two signals matched.
        XCTAssertEqual(technologies?.map(\.name), ["Next.js", "React", "Vite"])
        XCTAssertEqual(technologies?.first?.detail, "the __NEXT_DATA__ payload")
        XCTAssertTrue(DeveloperDiagnostics.technologies(from: ["laravel"]).isEmpty)
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

    func testDirectWebURLAcceptsAHostnameAndRejectsNonWebSchemes() {
        XCTAssertEqual(BrowserAddress.directWebURL(from: "youtube.com")?.absoluteString, "https://youtube.com")
        XCTAssertNil(BrowserAddress.directWebURL(from: "mailto:hello@example.com"))
    }

    @MainActor
    func testSmartAddressSuggestionsUseTheSelectedSearchEngine() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let settings = BrowserSettings(persistence: persistence)
        settings.searchEngine = .duckDuckGo
        let store = BrowserStore(settings: settings, persistence: persistence)

        guard case let .search(query, engine) = store.smartAddressSuggestions(for: "quiet workspace").first else {
            return XCTFail("Expected a search suggestion")
        }
        XCTAssertEqual(query, "quiet workspace")
        XCTAssertEqual(engine.rawValue, BrowserSearchEngine.duckDuckGo.rawValue)
    }

    /// One fixture for both address bar tests: the same page is open, visited often and today,
    /// while a rarely visited host and a bookmark compete with it for the same query.
    @MainActor
    private func rankedGitSuggestions() -> [AddressSuggestion] {
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pulls = URL(string: "https://github.com/jungle/pulls")!
        let history = [
            BrowsingHistoryEntry(profileID: profileID, title: "Pull requests", address: pulls, visitedAt: now.addingTimeInterval(-600)),
            BrowsingHistoryEntry(profileID: profileID, title: "Pull requests", address: pulls, visitedAt: now.addingTimeInterval(-4_000)),
            BrowsingHistoryEntry(profileID: profileID, title: "Pull requests", address: pulls, visitedAt: now.addingTimeInterval(-9_000)),
            BrowsingHistoryEntry(
                profileID: profileID,
                title: "Notes",
                address: URL(string: "https://gist.github.com/notes")!,
                visitedAt: now.addingTimeInterval(-60 * 86_400)
            )
        ]

        return BrowserStore.rankedAddressSuggestions(
            for: "git",
            tabs: [BrowserTab(profileID: profileID, address: pulls, title: "Pull requests")],
            bookmarks: [BrowserBookmark(title: "Git news", address: URL(string: "https://news.ycombinator.com/git")!)],
            history: history,
            now: now
        )
    }

    @MainActor
    func testAddressSuggestionsRankByFrecencyAndDeduplicateByURL() {
        let ranked = rankedGitSuggestions()

        XCTAssertEqual(
            ranked.map(\.address.absoluteString),
            [
                "https://github.com/jungle/pulls",
                "https://news.ycombinator.com/git",
                "https://gist.github.com/notes"
            ]
        )
        XCTAssertEqual(ranked.first?.source, .tab)
    }

    @MainActor
    func testInlineCompletionFinishesTheTopRankedAddress() {
        let suggestions = rankedGitSuggestions().map(SmartAddressSuggestion.saved)

        XCTAssertEqual(BrowserStore.inlineCompletion(for: "git", in: suggestions), "github.com")
        XCTAssertEqual(BrowserStore.inlineCompletion(for: "github.com/jun", in: suggestions), "github.com/jungle/pulls")
        XCTAssertNil(BrowserStore.inlineCompletion(for: "https://git", in: suggestions))
        XCTAssertNil(BrowserStore.inlineCompletion(for: "git news", in: suggestions))
        XCTAssertNil(BrowserStore.inlineCompletion(for: "g", in: suggestions))
    }

    @MainActor
    func testArrowKeyHighlightStopsAtBothEndsOfTheList() {
        XCTAssertEqual(BrowserStore.highlightedSuggestionIndex(from: nil, step: 1, count: 3), 0)
        XCTAssertEqual(BrowserStore.highlightedSuggestionIndex(from: nil, step: -1, count: 3), 2)
        XCTAssertEqual(BrowserStore.highlightedSuggestionIndex(from: 1, step: 1, count: 3), 2)
        XCTAssertNil(BrowserStore.highlightedSuggestionIndex(from: 2, step: 1, count: 3))
        XCTAssertNil(BrowserStore.highlightedSuggestionIndex(from: 0, step: -1, count: 3))
        XCTAssertNil(BrowserStore.highlightedSuggestionIndex(from: nil, step: 1, count: 0))
    }

    func testYouTubeIsAValidNewTabDestination() {
        XCTAssertEqual(
            BrowserNewTabDestination.youtube.url(searchEngine: .duckDuckGo, customAddress: "").host,
            "www.youtube.com"
        )
    }

    func testNativeNewTabDestinationUsesTheJunglePage() {
        XCTAssertTrue(
            BrowserAddress.isNativeNewTab(
                BrowserNewTabDestination.native.url(searchEngine: .google, customAddress: "")
            )
        )
    }

    func testInvalidCustomNewTabDestinationFallsBackToSearchEngine() {
        XCTAssertEqual(
            BrowserNewTabDestination.custom.url(searchEngine: .brave, customAddress: "not a web address").host,
            "search.brave.com"
        )
    }

    func testCustomNewTabDestinationAcceptsAHostname() {
        XCTAssertEqual(
            BrowserNewTabDestination.custom.url(searchEngine: .google, customAddress: "youtube.com").host,
            "youtube.com"
        )
    }

    @MainActor
    func testNewTabsUseTheConfiguredDestination() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let settings = BrowserSettings(persistence: persistence)
        settings.newTabDestination = .youtube
        let reloadedSettings = BrowserSettings(persistence: persistence)
        let store = BrowserStore(settings: reloadedSettings, persistence: persistence)

        XCTAssertEqual(store.selectedTab?.address.host, "www.youtube.com")
        store.createTab()
        XCTAssertEqual(store.selectedTab?.address.host, "www.youtube.com")
    }

    @MainActor
    func testNativeNewTabsDoNotExposeAnInternalAddress() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let settings = BrowserSettings(persistence: persistence)
        settings.newTabDestination = .native
        let store = BrowserStore(settings: settings, persistence: persistence)

        XCTAssertTrue(store.selectedTab?.isNativeNewTab == true)
        XCTAssertEqual(store.selectedTabAddressText, "")
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
    func testQuickAccessBookmarkOpensOnItsTileInsteadOfTheTabList() throws {
        let store = makeStore()
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let bookmark = try XCTUnwrap(quickAccess.bookmarks.first)
        let listedTabIDs = store.listedTabs.map(\.id)

        store.openQuickAccessBookmark(bookmark)

        let tabID = try XCTUnwrap(store.quickAccessTabID(for: bookmark.id))
        XCTAssertEqual(store.selectedTabID, tabID)
        XCTAssertTrue(store.isQuickAccessBookmarkActive(bookmark.id))
        XCTAssertTrue(store.tabs.contains(where: { $0.id == tabID }))
        XCTAssertEqual(store.listedTabs.map(\.id), listedTabIDs, "A tile's tab must stay out of the tab list")

        store.openQuickAccessBookmark(bookmark)

        XCTAssertEqual(store.quickAccessTabID(for: bookmark.id), tabID, "Reopening a tile must not open a second tab")
        XCTAssertEqual(store.tabs.filter { $0.address == bookmark.address }.count, 1)
    }

    @MainActor
    func testClosingQuickAccessTileLeavesAListedTabSelected() throws {
        let store = makeStore()
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let bookmark = try XCTUnwrap(quickAccess.bookmarks.first)
        store.openQuickAccessBookmark(bookmark)

        store.closeQuickAccessBookmark(bookmark.id)

        XCTAssertNil(store.quickAccessTabID(for: bookmark.id))
        XCTAssertFalse(store.isQuickAccessBookmarkActive(bookmark.id))
        let selectedTabID = try XCTUnwrap(store.selectedTabID)
        XCTAssertTrue(store.listedTabs.contains(where: { $0.id == selectedTabID }), "Closing a tile must land on a tab the sidebar shows")
    }

    @MainActor
    func testQuickAccessTabReturnsToTheTabListWhenItsBookmarkLeaves() throws {
        let store = makeStore()
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let readingList = try XCTUnwrap(store.visibleBookmarkFolders.first(where: { !$0.isQuickAccess }))
        let bookmark = try XCTUnwrap(quickAccess.bookmarks.first)
        store.openQuickAccessBookmark(bookmark)
        let tabID = try XCTUnwrap(store.quickAccessTabID(for: bookmark.id))

        store.moveBookmark(bookmark.id, from: quickAccess.id, to: readingList.id)

        XCTAssertTrue(store.listedTabs.contains(where: { $0.id == tabID }), "A tab must never be left with no way to reach it")
    }

    @MainActor
    func testCustomBookmarkSymbolSurvivesAReload() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let store = BrowserStore(persistence: persistence)
        let quickAccess = try XCTUnwrap(store.visibleBookmarkFolders.first(where: \.isQuickAccess))
        let bookmarkID = try XCTUnwrap(quickAccess.bookmarks.first?.id)

        store.setBookmarkSymbol("bolt.fill", for: bookmarkID, in: quickAccess.id)

        XCTAssertEqual(
            BrowserStore(persistence: persistence).visibleBookmarkFolders
                .flatMap(\.bookmarks).first(where: { $0.id == bookmarkID })?.customSymbol,
            "bolt.fill"
        )

        store.setBookmarkSymbol(nil, for: bookmarkID, in: quickAccess.id)

        XCTAssertNil(
            BrowserStore(persistence: persistence).visibleBookmarkFolders
                .flatMap(\.bookmarks).first(where: { $0.id == bookmarkID })?.customSymbol
        )
    }

    /// The page reports what the pointer is over keyed by WebKit's own menu item identifiers.
    /// If the two lists ever drift apart, context menu downloads go silently dead again.
    @MainActor
    func testContextMenuScriptReportsEveryDownloadableElement() {
        let source = JungleWebView.contextMenuScript.source

        for identifier in JungleWebView.downloadItemIdentifiers {
            XCTAssertTrue(source.contains(identifier), "\(identifier) is never reported by the page")
        }
        XCTAssertTrue(source.contains("node.closest(selector)"), "an image inside a link must still answer")
        XCTAssertTrue(source.contains("'img'"))
        XCTAssertTrue(source.contains("'a[href]'"))
        XCTAssertTrue(source.contains("'video, audio'"))
        XCTAssertFalse(JungleWebView.contextMenuScript.isForMainFrameOnly, "images inside an iframe download too")
    }

    @MainActor
    func testPooledWebViewsCanServeTheirOwnContextMenuDownloads() {
        let profile = BrowserProfile(name: "Downloads", symbol: "arrow.down", tint: .green)
        let tab = BrowserTab(profileID: profile.id)
        defer { WebViewPool.shared.discard(tab.id) }

        let webView = WebViewPool.shared.webView(for: tab, profile: profile)

        XCTAssertTrue(webView is JungleWebView, "WebKit's download menu items need a view that can re-point them")
        let scripts = webView.configuration.userContentController.userScripts
        XCTAssertTrue(scripts.contains { $0.source == JungleWebView.contextMenuScript.source })
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

    func testSidebarDragSnapsToTheNearestStep() {
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: 400), .snapped(.full))
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: 235), .snapped(.full))
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: 233), .snapped(.regular))
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: 149), .snapped(.regular))
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: 147), .snapped(.compact))
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: 71), .snapped(.compact))
    }

    func testSidebarHidesOnlyWhenDraggedPastTheNarrowestStep() {
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: SidebarStep.hideThreshold), .snapped(.compact))
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: SidebarStep.hideThreshold - 1), .hidden)
        XCTAssertEqual(SidebarStep.resolve(draggedWidth: -40), .hidden)
    }

    @MainActor
    func testSidebarWidthPersistsAcrossLaunches() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let settings = BrowserSettings(persistence: persistence)

        settings.sidebarWidth = SidebarStep.compact.width

        XCTAssertEqual(BrowserSettings(persistence: persistence).sidebarWidth, SidebarStep.compact.width)
    }

    @MainActor
    func testSidebarWidthDefaultsToFullWhenNothingWasSaved() throws {
        let settings = BrowserSettings(persistence: try BrowserPersistence(testingInMemory: true))

        XCTAssertEqual(settings.sidebarWidth, SidebarStep.full.width)
    }

    func testContentBlockingUsesFallbackWhenAnyPrimarySourceIsUnavailable() {
        XCTAssertTrue(ContentBlockingSourcePolicy.shouldUseFallback(primarySourcesAreUsable: [true, false]))
        XCTAssertFalse(ContentBlockingSourcePolicy.shouldUseFallback(primarySourcesAreUsable: [true, true]))
    }

    func testWindowHeaderDoubleClickActionFollowsSystemPreference() {
        XCTAssertEqual(WindowHeaderDoubleClickAction.resolved(from: "Maximize"), .zoom)
        XCTAssertEqual(WindowHeaderDoubleClickAction.resolved(from: "Minimize"), .minimize)
        XCTAssertEqual(WindowHeaderDoubleClickAction.resolved(from: "None"), .ignore)
        XCTAssertEqual(WindowHeaderDoubleClickAction.resolved(from: "minimize"), .minimize)
    }

    func testWindowHeaderDoubleClickActionZoomsWhenPreferenceIsMissingOrUnknown() {
        XCTAssertEqual(WindowHeaderDoubleClickAction.resolved(from: nil), .zoom)
        XCTAssertEqual(WindowHeaderDoubleClickAction.resolved(from: "Fill"), .zoom)
    }

    func testWindowHeaderDoubleClickActionReadsTheGlobalPreferenceKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "jungle.tests.\(UUID().uuidString)"))
        defer { defaults.removeObject(forKey: WindowHeaderDoubleClickAction.preferenceKey) }
        defaults.set("None", forKey: WindowHeaderDoubleClickAction.preferenceKey)

        XCTAssertEqual(WindowHeaderDoubleClickAction.systemPreference(in: defaults), .ignore)
    }
}

@MainActor
private final class NavigationCompletion: NSObject, WKNavigationDelegate {
    let finished = XCTestExpectation(description: "Web view finished loading")

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
}
