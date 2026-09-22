import XCTest
import WebKit
@testable import jungle

final class JungleTests: XCTestCase {
    /// Never the shared store: these tests used to read and rewrite the real browsing database.
    @MainActor
    private func makeStore() -> BrowserStore {
        BrowserStore(persistence: try! BrowserPersistence(testingInMemory: true))
    }

    /// Google Sheets halves its grid canvas for a Safari it reads as old, so the version in
    /// the user agent is what keeps a spreadsheet sharp. The agent has to stay a Safari agent,
    /// and the version it carries has to be one no older than the `18.6` that caused the blur.
    @MainActor
    func testSafariUserAgentCarriesAVersionNewerThanTheOneSheetsDegrades() {
        let agent = WebViewPool.safariUserAgent

        XCTAssertTrue(agent.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "), agent)
        XCTAssertTrue(agent.hasSuffix(" Safari/605.1.15"), agent)

        guard let version = agent.components(separatedBy: "Version/").last?.components(separatedBy: " ").first,
              let major = Int(version.components(separatedBy: ".").first ?? "")
        else { return XCTFail("no version in \(agent)") }
        // Deriving the version from the OS only holds while Safari ships the OS version, which
        // started at macOS 26. An older system would silently hand Sheets a stale Safari again.
        XCTAssertGreaterThanOrEqual(major, 26, agent)
    }

    /// A capture prompt covers one device or both, so a pair of stored answers has to settle
    /// the combined request: any block denies, all allows grant, anything else still asks.
    @MainActor
    func testSitePermissionsCombineStoredDeviceAnswers() {
        let origin = "https://tests.jungle.invalid"
        defer { SitePermissions.forget([.camera, .microphone, .notifications], for: origin) }

        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]))

        SitePermissions.remember(true, for: origin, kinds: [.camera])
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera]), true)
        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]))

        SitePermissions.remember(true, for: origin, kinds: [.microphone])
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]), true)

        SitePermissions.remember(false, for: origin, kinds: [.microphone])
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera, .microphone]), false)
        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.notifications]))

        // Revoking one kind from Settings leaves the site's other answers alone.
        SitePermissions.remember(true, for: origin, kinds: [.notifications])
        SitePermissions.forget([.notifications], for: origin)
        XCTAssertNil(SitePermissions.decision(for: origin, kinds: [.notifications]))
        XCTAssertEqual(SitePermissions.decision(for: origin, kinds: [.camera]), true)
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
        let quickAccess = BrowserTab(profileID: profileID, lastActivatedAt: cutoff.addingTimeInterval(-60))
        let all = [idle, selected, pinned, recent, quickAccess]

        let candidates = BrowserStore.idleTabs(in: all, cutoff: cutoff, selectedTabID: selected.id, quickAccessTabIDs: [quickAccess.id])

        XCTAssertEqual(candidates.map(\.id), [idle.id])
        let underPressure = BrowserStore.idleTabs(
            in: all, cutoff: cutoff, selectedTabID: selected.id, quickAccessTabIDs: [quickAccess.id], includesPinned: true
        )
        XCTAssertEqual(underPressure.map(\.id), [idle.id, pinned.id, quickAccess.id])
    }

    /// The hint shows only when ⌘B never reached the menu: a toggle after the press means the
    /// page let it through. Toggling, or leaving the tab, takes the hint down.
    @MainActor
    func testSidebarShortcutHintShowsOnlyWhenThePageKeptTheKey() throws {
        let store = BrowserStore(persistence: try BrowserPersistence(testingInMemory: true))
        let tabID = try XCTUnwrap(store.selectedTabID)

        let letThrough = Date.now
        store.toggleSidebar()
        store.sidebarShortcutReachedPage(in: tabID, pressedAt: letThrough)
        XCTAssertFalse(store.isSidebarShortcutHintVisible)

        store.sidebarShortcutReachedPage(in: UUID(), pressedAt: .now)
        XCTAssertFalse(store.isSidebarShortcutHintVisible)

        store.sidebarShortcutReachedPage(in: tabID, pressedAt: .now)
        XCTAssertTrue(store.isSidebarShortcutHintVisible)

        let wasVisible = store.isSidebarVisible
        store.toggleSidebar()
        XCTAssertFalse(store.isSidebarShortcutHintVisible)
        XCTAssertNotEqual(store.isSidebarVisible, wasVisible)
    }

    /// Against real WebKit: a page that takes ⌘B is reported once the page has answered, and
    /// the armed second press goes to the sidebar without the page ever seeing it.
    @MainActor
    func testSidebarShortcutIsReportedWhenThePageKeepsItAndBypassesThePageWhenArmed() async throws {
        let configuration = WKWebViewConfiguration()
        let pageKeys = PageKeyMessages()
        configuration.userContentController.add(pageKeys, name: "keys")
        let webView = JungleWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(webView)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<body contenteditable>text<script>addEventListener('keydown', e => { if (e.metaKey && e.key === 'b') { e.preventDefault(); webkit.messageHandlers.keys.postMessage('b'); } });</script>",
            baseURL: URL(string: "https://bold.jungle.test")
        )
        await fulfillment(of: [navigation.finished], timeout: 5)
        window.makeFirstResponder(webView)

        let reached = expectation(description: "The page answered the key")
        webView.sidebarShortcutReachedPage = { _ in reached.fulfill() }
        XCTAssertTrue(webView.performKeyEquivalent(with: try Self.commandB(in: window)))
        await fulfillment(of: [reached], timeout: 5)
        XCTAssertEqual(pageKeys.count, 1)

        webView.sidebarShortcutIsArmed = { true }
        webView.sidebarShortcutReachedPage = { _ in XCTFail("An armed press must not go to the page") }
        let toggled = expectation(forNotification: .jungleToggleSidebar, object: nil)
        XCTAssertTrue(webView.performKeyEquivalent(with: try Self.commandB(in: window)))
        await fulfillment(of: [toggled], timeout: 1)
        _ = try await webView.evaluateJavaScript("1")
        XCTAssertEqual(pageKeys.count, 1)
    }

    private static func commandB(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b",
            isARepeat: false, keyCode: 11
        ))
    }

    @MainActor
    func testMemoryPressureShortensTheSleepDelay() {
        XCTAssertEqual(BrowserStore.sleepDelay(interval: 900, pressure: .normal), 900)
        XCTAssertEqual(BrowserStore.sleepDelay(interval: 900, pressure: .warning), 60)
        XCTAssertEqual(BrowserStore.sleepDelay(interval: 30, pressure: .warning), 30)
        XCTAssertEqual(BrowserStore.sleepDelay(interval: 900, pressure: .critical), 0)
    }

    /// Idle time has to be measured from when a tab stopped being selected, not from when it
    /// was last selected. A tab read for a long while and then left moments ago must not read
    /// as idle under a full 15-minute interval — that was the "tabs sleep in under a minute"
    /// bug: only the arriving tab got a fresh timestamp, so the one being left kept whatever
    /// timestamp it had from being selected long ago.
    @MainActor
    func testLeavingATabStampsItsOwnLastActivatedAtSoItIsNotImmediatelyIdle() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)
        let profiles = persistence.loadProfiles()
        let profileID = profiles[0].id
        let longAgo = Date.now.addingTimeInterval(-3600)
        let readTab = BrowserTab(profileID: profileID, address: BrowserAddress.home, title: "Read a while ago", lastActivatedAt: longAgo)
        let otherTab = BrowserTab(profileID: profileID, address: BrowserAddress.home, title: "Other tab", lastActivatedAt: longAgo)
        persistence.saveWorkspace(tabs: [readTab, otherTab], profiles: profiles, activeProfileID: profileID, selectedTabID: readTab.id)

        let store = BrowserStore(persistence: persistence)
        XCTAssertEqual(store.selectedTabID, readTab.id)

        // Switching away from `readTab` is the "left just now" moment.
        store.select(otherTab.id)

        let cutoff = Date.now.addingTimeInterval(-900)
        let idle = BrowserStore.idleTabs(in: store.tabs, cutoff: cutoff, selectedTabID: store.selectedTabID)

        XCTAssertFalse(idle.contains(where: { $0.id == readTab.id }))
    }

    /// The zoom ladder: both ends clamp, and stepping out and back in lands on exactly 1.0
    /// rather than on a drifted neighbour that would leave the badge reading 99%.
    @MainActor
    func testPageZoomStepsClampAndRoundTrip() {
        XCTAssertEqual(BrowserStore.pageZoomStep(above: 1), 1.1)
        XCTAssertEqual(BrowserStore.pageZoomStep(below: 1), 0.9)
        XCTAssertEqual(BrowserStore.pageZoomStep(above: 3), 3)
        XCTAssertEqual(BrowserStore.pageZoomStep(below: 0.5), 0.5)
        XCTAssertEqual(BrowserStore.pageZoomStep(below: BrowserStore.pageZoomStep(above: 1)), 1)
        XCTAssertEqual(BrowserStore.pageZoomStep(above: BrowserStore.pageZoomStep(below: 1)), 1)
    }

    /// A failed load leaves the web view blank, so the tab renders the failure instead. A
    /// cancelled load is not a failure: it is what every interrupted navigation reports.
    func testNavigationFailureDescribesTheErrorAndIgnoresCancellations() {
        let address = URL(string: "https://nope.example")!
        let notFound = NavigationFailure(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost),
            address: address
        )

        XCTAssertEqual(notFound?.title, "Site not found")
        XCTAssertTrue(notFound?.message.contains("nope.example") ?? false)
        XCTAssertNil(NavigationFailure(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), address: address))
        XCTAssertNil(NavigationFailure(error: NSError(domain: "WebKitErrorDomain", code: 102), address: address))
        // Anything outside the URL domain still gets a page, carrying the system's own wording.
        XCTAssertEqual(
            NavigationFailure(error: NSError(domain: "SomeOtherDomain", code: -1004), address: address)?.title,
            "This page didn't load"
        )
    }

    /// ⌘1…⌘9 address the Quick Access tiles in the order the sidebar shows them, and a number
    /// past the last tile has to do nothing rather than open something else.
    @MainActor
    func testQuickAccessNumberOpensTheTileInThatPosition() {
        let store = makeStore()
        let tiles = store.quickAccessBookmarks
        guard tiles.count >= 2 else { return XCTFail("expected the default Quick Access tiles") }
        let tabCountBefore = store.tabs.count

        store.openQuickAccessBookmark(number: 2)

        XCTAssertEqual(store.quickAccessTabID(for: tiles[1].id), store.selectedTabID)
        XCTAssertEqual(store.selectedTab?.address, tiles[1].address)

        // The same number again returns to the tile it already owns instead of opening a copy.
        let openedTabID = store.selectedTabID
        store.openQuickAccessBookmark(number: 2)
        XCTAssertEqual(store.selectedTabID, openedTabID)
        XCTAssertEqual(store.tabs.count, tabCountBefore + 1)

        store.openQuickAccessBookmark(number: tiles.count + 1)
        store.openQuickAccessBookmark(number: 0)
        XCTAssertEqual(store.selectedTabID, openedTabID)
        XCTAssertEqual(store.tabs.count, tabCountBefore + 1)
    }

    /// A `target="_blank"` link that is itself a download must not open a tab: WebKit
    /// downloads it from the page that asked, and a tab beside it fetched the same file again
    /// and then sat blank forever.
    @MainActor
    func testNewWindowDestinationSkipsDownloadsAndNonWebAddresses() {
        let address = URL(string: "https://example.com/image.png")!

        XCTAssertEqual(BrowserStore.newWindowDestination(shouldPerformDownload: false, requestURL: address), address)
        XCTAssertNil(BrowserStore.newWindowDestination(shouldPerformDownload: true, requestURL: address))
        XCTAssertNil(BrowserStore.newWindowDestination(shouldPerformDownload: false, requestURL: nil))
        XCTAssertNil(BrowserStore.newWindowDestination(
            shouldPerformDownload: false,
            requestURL: URL(string: "mailto:someone@example.com")
        ))
    }

    /// A tab a link opened only to carry a download never receives a document, so it closes
    /// itself instead of staying behind as a blank page the user has to clean up.
    @MainActor
    func testTabOpenedOnlyForADownloadCloses() async {
        let store = makeStore()
        store.createTab()
        guard let tabID = store.selectedTabID else { return XCTFail("no tab") }
        let tabCount = store.tabs.count

        store.closeTabOpenedForDownload(tabID)

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertEqual(store.tabs.count, tabCount - 1)
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

        XCTAssertTrue(source.contains("isPlaying(activeVideo)"))
        XCTAssertFalse(source.contains("playingVideo() || document.querySelector('video')"))
        XCTAssertFalse(source.contains("pictureInPictureDidChange"), "WebKit's delegate owns the floating window's state")
    }

    /// Anime and video hosts nest their player two or three cross-origin frames deep, where a
    /// main-frame script never sees it. Every frame reports the video it plays, once WebKit
    /// can present it, and keeps sound and the tab mute to the main frame.
    @MainActor
    func testMediaScriptReachesPlayersInEmbeddedFrames() {
        let script = WebViewPool.mediaScript
        let source = script.source

        XCTAssertFalse(script.isForMainFrameOnly)
        XCTAssertTrue(source.contains("addEventListener('playing'"), "`play` fires before WebKit can present the video")
        XCTAssertTrue(source.contains("videoDidPlay"))
        XCTAssertTrue(source.contains("if (!isTopFrame)"), "Only the main frame reports sound and applies the mute")
        XCTAssertTrue(source.contains("shadowRoot"), "Players inside shadow roots are searched too")
        XCTAssertTrue(source.contains("disablePictureInPicture = false"))
    }

    /// Find counts and moves through WebKit's own `NSTextFinder` document calls. A WebKit that
    /// dropped one falls back to the uncounted public search; this says so before a user does.
    @MainActor
    func testFindInPageUsesWebKitsCountedSearch() {
        XCTAssertTrue(PageFinder.canCount(in: WKWebView(frame: .zero)))
    }

    /// A search starts where the reader is, never back at the top of the page.
    func testFindStartsAtTheFirstMatchFromWhereTheReaderIs() {
        let origins = [CGPoint(x: 10, y: 8), CGPoint(x: 90, y: 8), CGPoint(x: 10, y: 600), CGPoint(x: 90, y: 600)]

        XCTAssertEqual(FindInPage.firstIndex(in: origins, from: .zero), 0)
        XCTAssertEqual(FindInPage.firstIndex(in: origins, from: CGPoint(x: 0, y: 300)), 2, "First match below the top of the screen")
        XCTAssertEqual(FindInPage.firstIndex(in: origins, from: CGPoint(x: 90, y: 8)), 1, "Typing keeps the match already shown")
        XCTAssertEqual(FindInPage.firstIndex(in: origins, from: CGPoint(x: 0, y: 900)), 0, "Past the last match it wraps")
    }

    /// `_isPictureInPictureActive` reads false for a window opened from an embedded player, so
    /// the delegate's answer is what keeps the tab's view in the window.
    @MainActor
    func testPictureInPictureStateFollowsTheDelegateForEmbeddedPlayers() throws {
        let store = makeStore()
        let tab = try XCTUnwrap(store.selectedTab)
        let profile = try XCTUnwrap(store.profiles.first(where: { $0.id == tab.profileID }))
        _ = WebViewPool.shared.webView(for: tab, profile: profile)
        defer { WebViewPool.shared.discard(tab.id) }

        XCTAssertFalse(WebViewPool.shared.isPictureInPictureActive(tab.id))
        WebViewPool.shared.pictureInPictureDidChange(isActive: true, tabID: tab.id)
        XCTAssertTrue(WebViewPool.shared.isPictureInPictureActive(tab.id))
        WebViewPool.shared.pictureInPictureDidChange(isActive: false, tabID: tab.id)
        XCTAssertFalse(WebViewPool.shared.isPictureInPictureActive(tab.id))

        WebViewPool.shared.pictureInPictureDidChange(isActive: true, tabID: tab.id)
        WebViewPool.shared.discard(tab.id)
        XCTAssertFalse(WebViewPool.shared.isPictureInPictureActive(tab.id), "A discarded tab holds no window")
    }

    /// The page script never sees a video inside an embedded frame or a shadow root, so the
    /// floating window is tracked through WebKit's own delegate call. A renamed selector, or a
    /// WebKit that dropped it, fails here instead of silently hiding tabs that own a window.
    @MainActor
    func testPictureInPictureStateComesFromWebKitDelegate() throws {
        let selector = NSSelectorFromString("_webView:hasVideoInPictureInPictureDidChange:")
        XCTAssertTrue(BrowserWebView.Coordinator.instancesRespond(to: selector))
        let delegateProtocol = try XCTUnwrap(objc_getProtocol("WKUIDelegatePrivate"))
        XCTAssertNotNil(protocol_getMethodDescription(delegateProtocol, selector, false, true).name)
        let webView = WKWebView(frame: .zero)
        ["_isPictureInPictureActive", "_canTogglePictureInPicture", "_togglePictureInPicture"].forEach {
            XCTAssertTrue(webView.responds(to: NSSelectorFromString($0)), $0)
        }
    }

    /// The sandbox grants `com.apple.PIPAgent` only to a process that already has PIP.framework
    /// loaded; without it every floating window stalls before it appears.
    func testPictureInPictureFrameworkIsLinked() {
        XCTAssertTrue(WebViewPool.supportsPictureInPicture)
        XCTAssertNotNil(dlopen("/System/Library/PrivateFrameworks/PIP.framework/Versions/A/PIP", RTLD_NOLOAD))
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

    /// An "Open App" button sends an address only another app can load. Everything WebKit
    /// loads itself, and the app's own new-tab page, stays in the browser.
    func testRecognizesAddressesThatBelongToAnotherApp() throws {
        for address in ["claude://login/callback?code=1", "zoommtg://zoom.us/join", "mailto:hello@example.com", "tel:+15551234567", "itms-apps://apps.apple.com/app/id1", "VSCODE://file/tmp"] {
            XCTAssertTrue(BrowserAddress.opensInAnotherApp(try XCTUnwrap(URL(string: address))), address)
        }
        for address in ["https://example.com", "http://example.com", "about:blank", "blob:https://example.com/1", "data:text/plain,hi", "javascript:void(0)", "wss://example.com/socket", "jungle://new-tab", "relative/path"] {
            XCTAssertFalse(BrowserAddress.opensInAnotherApp(try XCTUnwrap(URL(string: address))), address)
        }
        XCTAssertFalse(BrowserAddress.opensInAnotherApp(URL(fileURLWithPath: "/tmp/example")))
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

    /// A link opened from another app (the terminal, Mail) gets its own tab and leaves the
    /// page the user was on where it was.
    @MainActor
    func testExternalLinkOpensInNewTabWithoutReplacingSelectedOne() throws {
        let store = makeStore()
        let previousTab = try XCTUnwrap(store.selectedTab)
        let initialTabCount = store.tabs.count
        let destination = try XCTUnwrap(URL(string: "https://example.com/from-terminal"))

        store.openExternalURL(destination)

        XCTAssertEqual(store.tabs.count, initialTabCount + 1)
        XCTAssertNotEqual(store.selectedTabID, previousTab.id)
        XCTAssertEqual(store.selectedTab?.address, destination)
        XCTAssertEqual(store.tabs.first(where: { $0.id == previousTab.id })?.address, previousTab.address)
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
                requestURL: destination
            ),
            destination
        )
        XCTAssertNil(
            BrowserStore.commandClickDestination(
                navigationType: .linkActivated,
                modifierFlags: [],
                requestURL: destination
            )
        )
        XCTAssertNil(
            BrowserStore.commandClickDestination(
                navigationType: .linkActivated,
                modifierFlags: .command,
                requestURL: URL(string: "mailto:someone@example.com")
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
        XCTAssertTrue(scripts.contains { $0.source == ScreenShareQuality.scriptSource })

        WebViewPool.shared.discard(tab.id)
        try? await WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID)
    }

    /// A shared screen is sent as text: WebKit's mock screen comes back marked `detail` and
    /// held at full resolution on the sender, the page's own size limit still stands, and a
    /// camera next to it keeps adapting the way it always did.
    @MainActor
    func testScreenShareKeepsResolutionWithoutTouchingTheCamera() async throws {
        let configuration = WKWebViewConfiguration()
        for key in ["mediaDevicesEnabled", "peerConnectionEnabled", "screenCaptureEnabled", "mockCaptureDevicesEnabled"] {
            configuration.preferences.setValue(true, forKey: key)
        }
        configuration.preferences.setValue(false, forKey: "mockCaptureDevicesPromptEnabled")
        configuration.userContentController.addUserScript(ScreenShareQuality.userScript)
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // WebKit only captures for a page that is on screen and focused.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let permissions = GrantingCapturePermissions()
        webView.uiDelegate = permissions
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<!doctype html><body></body>", baseURL: URL(string: "https://example.com/"))
        await fulfillment(of: [navigation.finished], timeout: 10)

        // Each capture is its own call, because each one spends the user gesture it came with.
        let steps = [
            "window.r = {}; window.pc = new RTCPeerConnection(); const t = (await navigator.mediaDevices.getDisplayMedia({video: {width: {max: 1280}}})).getVideoTracks()[0]; const s = pc.addTrack(t); r.screen = [t.getSettings().width, t.contentHint, s.getParameters().degradationPreference];",
            "const t = (await navigator.mediaDevices.getDisplayMedia()).getVideoTracks()[0]; const s = pc.addTransceiver('video').sender; await s.replaceTrack(t.clone()); r.replaced = [s.track.contentHint, s.getParameters().degradationPreference];",
            "const t = (await navigator.mediaDevices.getUserMedia({video: true})).getVideoTracks()[0]; const s = pc.addTrack(t); r.camera = [t.contentHint, s.getParameters().degradationPreference ?? null]; return JSON.stringify(r);"
        ]
        var result: Any?
        for step in steps { result = try await webView.callAsyncJavaScript(step, contentWorld: .page) }

        XCTAssertEqual(
            result as? String,
            #"{"screen":[1280,"detail","maintain-resolution"],"replaced":["detail","maintain-resolution"],"camera":["",null]}"#
        )
    }

    /// The two halves of an anti-adblock page: the detector that reports the blocker, and the
    /// wall it puts up afterwards. Neither knows about any particular site.
    @MainActor
    func testAntiAdblockDefusingAnswersDetectorsAndTakesDownTheWall() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(AntiAdblockDefusing.userScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            """
            <!doctype html><html><body>
            <div id="wall" style="position:fixed;top:0;left:0;width:100%;height:100%;z-index:9999">
            Please disable AdBlock to watch this video</div>
            <script>
              document.body.style.overflow = 'hidden';
              window.detectorSaidBlocked = null;
              var probe = new FuckAdBlock();
              probe.onDetected(function () { window.detectorSaidBlocked = true; });
              probe.onNotDetected(function () { window.detectorSaidBlocked = false; });
              probe.check();
            </script>
            </body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://player.example/watch"))
        )
        await fulfillment(of: [navigation.finished], timeout: 5)
        try await Task.sleep(for: .seconds(2))

        let result = try await webView.evaluateJavaScript(
            """
            [
                window.canRunAds === true,
                window.isAdBlockActive === false,
                window.detectorSaidBlocked === false,
                document.getElementById('wall') === null,
                getComputedStyle(document.body).overflow !== 'hidden'
            ].join(',')
            """
        ) as? String

        XCTAssertEqual(result, "true,true,true,true,true")
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

    private func networkRules(_ source: String) throws -> [[String: Any]] {
        let json = ContentBlockerRuleCompiler.compile(source).network
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private func cosmeticRules(_ source: String) throws -> [[String: Any]] {
        let json = ContentBlockerRuleCompiler.compile(source).cosmetic
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    func testContentRuleCompilerTranslatesHostRulesAndExceptions() throws {
        let rules = try networkRules("""
        ||ads.example.com^$script,third-party
        @@||ads.example.com^$domain=trusted.example
        """)

        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual((rules[0]["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertEqual((rules[0]["trigger"] as? [String: Any])?["resource-type"] as? [String], ["script"])
        XCTAssertEqual((rules[0]["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual((rules[1]["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
        // The leading star is what makes a domain cover its subdomains. Without it WebKit
        // matches the bare host only, which is never what a filter list means.
        XCTAssertEqual((rules[1]["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*trusted.example"])
    }

    func testContentRuleCompilerTranslatesPathFiltersHostRulesCannotReach() throws {
        let rules = try networkRules("""
        /banner-ads/*
        |http://ads.tracker.example/pixel|
        """)

        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertEqual(filters.count, 2)
        XCTAssertEqual(filters[0], "\\/banner-ads\\/.*")
        XCTAssertEqual(filters[1], "^http:\\/\\/ads\\.tracker\\.example\\/pixel$")
        XCTAssertTrue(filters.allSatisfy { (try? NSRegularExpression(pattern: $0)) != nil })
    }

    func testContentRuleCompilerDropsFiltersWebKitWouldRejectOrMisread() throws {
        let rules = try networkRules("""
        ||example.com^$csp=script-src 'none'
        ||example.com^$removeparam=fbclid
        ||example.com^$domain=entity.*
        ||no-dot-host^
        /ad
        """)

        // A header or parameter rule read as a block takes the whole site down with it, an
        // entity domain has no WebKit spelling, and a three-character pattern matches the web.
        XCTAssertTrue(rules.isEmpty)
    }

    func testContentRuleCompilerTranslatesElementHidingIntoItsOwnList() throws {
        let source = """
        ##.generic-ad
        shop.example,~news.example##.sponsored
        shop.example##div:has(> .promo)
        @@||shop.example^$elemhide
        """
        let network = try networkRules(source)
        let cosmetic = try cosmeticRules(source)

        // The element-hiding exception must not appear in the network list, or it would lift
        // that site's network blocking too.
        XCTAssertTrue(network.isEmpty)

        let hiding = cosmetic.filter { ($0["action"] as? [String: Any])?["type"] as? String == "css-display-none" }
        XCTAssertEqual(hiding.count, 2)
        XCTAssertNil((hiding[0]["trigger"] as? [String: Any])?["if-domain"])
        XCTAssertEqual((hiding[0]["action"] as? [String: Any])?["selector"] as? String, ".generic-ad")
        XCTAssertEqual((hiding[1]["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*shop.example"])
        // `:has()` is procedural in filter syntax; WebKit rejects the list that carries it.
        XCTAssertEqual((hiding[1]["action"] as? [String: Any])?["selector"] as? String, ".sponsored")
        XCTAssertEqual((cosmetic.last?["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
    }

    @MainActor
    func testGeneratedContentRulesCompileInWebKit() async throws {
        let ruleSet = ContentBlockerRuleCompiler.compile("""
        ||tracker.example^$third-party,script
        ##.generic-ad
        shop.example##.sponsored
        """)
        let store = try XCTUnwrap(WKContentRuleListStore.default())

        for source in [ruleSet.network, ruleSet.cosmetic] {
            let identifier = "jungle.tests.\(UUID().uuidString)"
            defer { Task { try? await store.removeContentRuleList(forIdentifier: identifier) } }
            let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source)
            XCTAssertEqual(try XCTUnwrap(list).identifier, identifier)
        }
    }

    func testScriptedPopupsAreSpacedOutAndClickedLinksAreNot() {
        let opened = Date()
        let interval = BrowserStore.scriptedPopupInterval

        // The first window a script asks for always opens: answering nil is what tells a page
        // its popup was blocked, and pages run a download fallback when they hear that.
        XCTAssertTrue(
            BrowserStore.shouldAllowPopup(
                isFromEmbeddedOtherSiteFrame: false, isLinkActivated: false, lastScriptedPopupAt: nil, now: opened
            )
        )
        // The rest of the burst does not.
        XCTAssertFalse(
            BrowserStore.shouldAllowPopup(
                isFromEmbeddedOtherSiteFrame: false,
                isLinkActivated: false,
                lastScriptedPopupAt: opened,
                now: opened.addingTimeInterval(interval / 2)
            )
        )
        XCTAssertTrue(
            BrowserStore.shouldAllowPopup(
                isFromEmbeddedOtherSiteFrame: false,
                isLinkActivated: false,
                lastScriptedPopupAt: opened,
                now: opened.addingTimeInterval(interval)
            )
        )
        // A second click is a second decision by the user, whenever it lands.
        XCTAssertTrue(
            BrowserStore.shouldAllowPopup(
                isFromEmbeddedOtherSiteFrame: false, isLinkActivated: true, lastScriptedPopupAt: opened, now: opened
            )
        )
    }

    /// An embedded video player that answers a click with a window to a throwaway ad domain is
    /// the popunder every streaming site ships, and no filter list reaches it: the frame is the
    /// content the user came for and the destination is new every time.
    @MainActor
    func testAdBlockingSwitchesDefaultToProtectedAndSurviveALaunch() throws {
        let persistence = try BrowserPersistence(testingInMemory: true)

        // Nothing chosen yet has to read as protected, or an existing install would come
        // back with its blocker switched off.
        let fresh = BrowserSettings(persistence: persistence)
        XCTAssertEqual(fresh.adBlocking, AdBlockingOptions())

        fresh.adBlocking.hidesBlockedAdSpace = false
        fresh.adBlocking.skipsYouTubeAds = false

        let reopened = BrowserSettings(persistence: persistence)
        XCTAssertFalse(reopened.adBlocking.hidesBlockedAdSpace)
        XCTAssertFalse(reopened.adBlocking.skipsYouTubeAds)
        // The switches the user never touched stay on.
        XCTAssertTrue(reopened.adBlocking.blocksAdsAndTrackers)
        XCTAssertTrue(reopened.adBlocking.bypassesAdblockWalls)
        XCTAssertTrue(reopened.adBlocking.blocksEmbeddedPlayerPopups)
    }

    @MainActor
    func testTurningOffEmbeddedPlayerPopupBlockingGivesThePlayerItsWindowBack() throws {
        let store = makeStore()
        let tabID = try XCTUnwrap(store.selectedTabID)

        XCTAssertFalse(store.allowsPopup(from: tabID, isFromEmbeddedOtherSiteFrame: true, isLinkActivated: true))

        store.settings.adBlocking.blocksEmbeddedPlayerPopups = false

        XCTAssertTrue(store.allowsPopup(from: tabID, isFromEmbeddedOtherSiteFrame: true, isLinkActivated: true))
        // The burst limit is a separate switch and still applies to the page's own scripts.
        XCTAssertTrue(store.allowsPopup(from: tabID, isFromEmbeddedOtherSiteFrame: false, isLinkActivated: false))
        XCTAssertFalse(store.allowsPopup(from: tabID, isFromEmbeddedOtherSiteFrame: false, isLinkActivated: false))
    }

    func testPopupsFromAnEmbeddedOtherSiteFrameNeverOpen() {
        // Scripted, and clicked as a link — these players put an anchor over the picture.
        for wasClickedAsLink in [false, true] {
            XCTAssertFalse(
                BrowserStore.shouldAllowPopup(
                    isFromEmbeddedOtherSiteFrame: true,
                    isLinkActivated: wasClickedAsLink,
                    lastScriptedPopupAt: nil
                )
            )
        }
    }

    func testAFrameCountsAsThePageItselfOnlyWhenItBelongsToTheSameSite() {
        XCTAssertTrue(BrowserStore.isSameSite(frameHost: "animeflv.or.at", pageHost: "animeflv.or.at"))
        // A page embedding its own player keeps the windows that player opens.
        XCTAssertTrue(BrowserStore.isSameSite(frameHost: "player.animeflv.or.at", pageHost: "animeflv.or.at"))
        XCTAssertFalse(BrowserStore.isSameSite(frameHost: "animeav1.uns.bio", pageHost: "animeflv.or.at"))
        // A frame with no origin of its own is not the page.
        XCTAssertFalse(BrowserStore.isSameSite(frameHost: "", pageHost: "animeflv.or.at"))
        XCTAssertFalse(BrowserStore.isSameSite(frameHost: nil, pageHost: "animeflv.or.at"))
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

    /// The copy shortcut has to hand over a link that still opens the same page. Campaign
    /// noise goes, and every parameter the server reads to pick what it renders stays.
    func testCopiedAddressDropsTrackersAndKeepsParametersThatSelectThePage() {
        func clean(_ address: String) -> String {
            guard let url = URL(string: address) else { return "invalid" }
            return BrowserAddress.withoutTrackingParameters(url).absoluteString
        }

        // YouTube: the share identifier goes, the video and its timestamp stay.
        XCTAssertEqual(
            clean("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1&t=42&si=Ab3d"),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1&t=42"
        )
        XCTAssertEqual(clean("https://youtu.be/dQw4w9WgXcQ?si=Ab3d&t=10"), "https://youtu.be/dQw4w9WgXcQ?t=10")

        // Amazon: the referrer path segment and the click attribution go, the variant stays.
        XCTAssertEqual(
            clean("https://www.amazon.com.mx/dp/B08N5WRWNW/ref=sr_1_3?crid=X1&qid=1700000000&psc=1&pd_rd_w=aB3"),
            "https://www.amazon.com.mx/dp/B08N5WRWNW?psc=1"
        )

        // A query that is nothing but trackers leaves no dangling question mark.
        XCTAssertEqual(clean("https://example.com/page?utm_source=news&fbclid=abc"), "https://example.com/page")

        // Mercado Libre hides its trackers in the fragment.
        XCTAssertEqual(
            clean("https://articulo.mercadolibre.com.mx/MLM-123-item#polycard_client=search&wid=MLM1&tracking_id=99"),
            "https://articulo.mercadolibre.com.mx/MLM-123-item"
        )

        // Fragments that are not query-shaped, and sites with no rule, come back untouched.
        XCTAssertEqual(clean("https://example.com/doc#section-2"), "https://example.com/doc#section-2")
        XCTAssertEqual(clean("https://example.com/a?si=keep&ref=keep&t=1"), "https://example.com/a?si=keep&ref=keep&t=1")
        XCTAssertEqual(clean("https://example.com/search?q=hello%20world&page=2"), "https://example.com/search?q=hello%20world&page=2")

        // A lookalike host must not inherit Amazon's rules.
        XCTAssertEqual(
            clean("https://amazon.com.attacker.example/dp/X/ref=sr_1_3?tag=abc"),
            "https://amazon.com.attacker.example/dp/X/ref=sr_1_3?tag=abc"
        )
    }


    /// The tab speaker only ever silences. Writing its unmuted state back on every
    /// `volumechange` undid the player's own mute button, so pressing mute inside a
    /// Facebook reel or the YouTube player left the sound playing.
    @MainActor
    func testPageMuteSurvivesTheTabSpeakerInsideWebKit() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(WebViewPool.mediaScript)
        controller.add(DiscardedMessages(), name: "jungleMedia")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<video id=\"page-muted\"></video><video id=\"tab-muted\"></video>",
            baseURL: try XCTUnwrap(URL(string: "https://www.facebook.com/reel/1"))
        )

        await fulfillment(of: [navigation.finished], timeout: 5)
        let result = try await webView.evaluateJavaScript(
            """
            (function () {
                const page = document.getElementById('page-muted');
                const tab = document.getElementById('tab-muted');

                // The player's own speaker button, and the event WebKit raises for it.
                page.muted = true;
                page.dispatchEvent(new Event('volumechange', { bubbles: true }));
                const survivedTheEvent = page.muted;

                __jungleMedia.setMuted(true);
                const silencedEverything = page.muted && tab.muted;

                // Unmuting the tab hands the sound back to what the tab silenced, and
                // leaves the video the page muted exactly as the page left it.
                __jungleMedia.setMuted(false);
                return [survivedTheEvent, silencedEverything, page.muted, !tab.muted].join(',');
            })();
            """,
            in: nil,
            contentWorld: .defaultClient
        ) as? String

        XCTAssertEqual(result, "true,true,true,true")
    }

    /// A page that opens a window has to be handed the window it asked for. Opening a tab of
    /// our own and answering `nil` reads to the page as a blocked popup, and a page that hears
    /// that runs its fallback — which is why one click on a Jira attachment downloaded the file
    /// twice and left a tab that opened and closed on its own.
    @MainActor
    func testWindowOpenIsAnsweredWithTheWindowThePageAskedFor() async throws {
        let store = makeStore()
        let coordinator = BrowserWebView.Coordinator(store: store)
        let tabID = try XCTUnwrap(store.selectedTabID)
        let tab = try XCTUnwrap(store.tabs.first(where: { $0.id == tabID }))
        let profile = try XCTUnwrap(store.profiles.first(where: { $0.id == tab.profileID }))
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        coordinator.attach(to: webView, tabID: tabID)

        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<p>attachment</p>",
            baseURL: try XCTUnwrap(URL(string: "https://jira.example.com/browse/X-1"))
        )
        await fulfillment(of: [navigation.finished], timeout: 5)
        webView.navigationDelegate = coordinator

        // Port 1 refuses at once, so the popup WebKit navigates never leaves this machine.
        let opened = try await webView.evaluateJavaScript(
            "String(window.open('https://127.0.0.1:1/attachment/1', '_blank'))",
            in: nil,
            contentWorld: .page
        ) as? String

        XCTAssertEqual(opened, "[object Window]")
        XCTAssertEqual(store.tabs.count, 2, "One window asked for is one tab opened")
    }

    /// A window opened only to hand an address to another app would sit blank once the app
    /// took it, so no tab is opened for it. The scheme here is one no app registers, which is
    /// also the case that must not put a prompt on screen.
    @MainActor
    func testWindowOpenForAnotherAppOpensNoTab() async throws {
        let store = makeStore()
        let coordinator = BrowserWebView.Coordinator(store: store)
        let tabID = try XCTUnwrap(store.selectedTabID)
        let tab = try XCTUnwrap(store.tabs.first(where: { $0.id == tabID }))
        let profile = try XCTUnwrap(store.profiles.first(where: { $0.id == tab.profileID }))
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        coordinator.attach(to: webView, tabID: tabID)

        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<p>sign in</p>", baseURL: try XCTUnwrap(URL(string: "https://login.example.com")))
        await fulfillment(of: [navigation.finished], timeout: 5)
        webView.navigationDelegate = coordinator

        let opened = try await webView.evaluateJavaScript(
            "String(window.open('jungle-tests-no-such-app://callback', '_blank'))",
            in: nil,
            contentWorld: .page
        ) as? String

        XCTAssertEqual(opened, "null")
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// A sign-in page that sends the tab itself to an app address is answered by the app, not
    /// the tab: the page stays where it was, with no spinner left running and no error page.
    @MainActor
    func testMainFrameNavigationToAnotherAppLeavesTheTabOnItsPage() async throws {
        let store = makeStore()
        let coordinator = BrowserWebView.Coordinator(store: store)
        let tabID = try XCTUnwrap(store.selectedTabID)
        let tab = try XCTUnwrap(store.tabs.first(where: { $0.id == tabID }))
        let profile = try XCTUnwrap(store.profiles.first(where: { $0.id == tab.profileID }))
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        coordinator.attach(to: webView, tabID: tabID)

        let page = try XCTUnwrap(URL(string: "https://login.example.com/done"))
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<p>signed in</p>", baseURL: page)
        await fulfillment(of: [navigation.finished], timeout: 5)
        webView.navigationDelegate = coordinator

        _ = try await webView.evaluateJavaScript(
            "location.href = 'jungle-tests-no-such-app://callback'; 'sent'",
            in: nil,
            contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(webView.url, page)
        XCTAssertFalse(store.loadingTabIDs.contains(tabID))
        XCTAssertNil(store.navigationFailures[tabID])
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// The observations a tab keeps on its web view end with the view. Held by the coordinator
    /// they outlived every closed tab, and attaching the same view again must not add more.
    @MainActor
    func testWebViewObservationsLiveExactlyAsLongAsTheirWebView() {
        let coordinator = BrowserWebView.Coordinator(store: makeStore())
        weak var released: JungleWebView?
        autoreleasepool {
            let webView = JungleWebView(frame: .zero, configuration: WKWebViewConfiguration())
            released = webView
            coordinator.attach(to: webView, tabID: UUID())
            coordinator.attach(to: webView, tabID: UUID())
            XCTAssertEqual(webView.observations.count, 2)
        }
        XCTAssertNil(released, "An observation kept on the view must not keep the view alive")
    }

    /// WebKit loads the popup it was handed. The tab it belongs to must not request the same
    /// address again: a second request for an attachment is a second download of the file.
    @MainActor
    func testPopupTabDoesNotRequestItsAddressASecondTime() throws {
        let store = makeStore()
        let sourceTabID = try XCTUnwrap(store.selectedTabID)
        let address = try XCTUnwrap(URL(string: "https://127.0.0.1:1/attachment/1"))
        let popupTabID = try XCTUnwrap(store.openPopupTab(from: sourceTabID, address: address))
        XCTAssertEqual(store.selectedTabID, popupTabID)

        store.loadSelectedTabIfNeeded()

        let popupTab = try XCTUnwrap(store.tabs.first(where: { $0.id == popupTabID }))
        let profile = try XCTUnwrap(store.profiles.first(where: { $0.id == popupTab.profileID }))
        let webView = WebViewPool.shared.webView(for: popupTab, profile: profile)
        XCTAssertFalse(webView.isLoading)
        XCTAssertNil(webView.url)
    }

    /// A download that arrives through a redirect must not be requested twice. Atlassian hands
    /// a Jira attachment over as a redirect to a signed media address, the web view moves to
    /// that address, and the response turns into a download without ever committing a document.
    /// Recording only the address originally asked for left the tab looking unloaded, so the
    /// next layout pass fetched the file again and every attachment was saved twice.
    @MainActor
    func testATabRedirectedIntoADownloadIsNotRequestedAgain() throws {
        let store = makeStore()
        let requested = try XCTUnwrap(URL(string: "https://example.test/attachment/content/1"))
        let redirected = try XCTUnwrap(URL(string: "https://cdn.example.test/binary?token=abc"))
        let sourceTabID = try XCTUnwrap(store.selectedTabID)
        let tabID = try XCTUnwrap(store.openPopupTab(from: sourceTabID, address: requested))

        // WebKit follows the redirect and publishes the address it landed on.
        store.didCommitNavigation(for: tabID, url: redirected)
        XCTAssertEqual(store.tabs.first(where: { $0.id == tabID })?.address, redirected)

        // The response became a download, so the web view still holds no document.
        store.loadSelectedTabIfNeeded()

        let tab = try XCTUnwrap(store.tabs.first(where: { $0.id == tabID }))
        let profile = try XCTUnwrap(store.profiles.first(where: { $0.id == tab.profileID }))
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        XCTAssertFalse(webView.isLoading, "The redirected address was already requested once")
        XCTAssertNil(webView.url)
    }

    /// AVKit's Picture in Picture window, or any callback still pending, keeps a `WKWebView`
    /// alive after its tab lets go, and the page kept a gigabyte of web process with it. The
    /// test holds the view the whole time, the way Picture in Picture did.
    @MainActor
    func testDiscardClosesThePageEvenWhileTheViewIsStillHeld() async throws {
        // The pool keeps a profile's store for the session, so a fresh one per run would pile
        // up on disk; one fixed store is reused instead.
        let dataStoreID = try XCTUnwrap(UUID(uuidString: "6A0C7E52-1D3B-4F4B-9C55-7A1E0D2B9F10"))
        let profile = BrowserProfile(name: "Discard", symbol: "person", tint: .green, dataStoreID: dataStoreID)
        let tab = BrowserTab(profileID: profile.id)
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        try XCTSkipUnless(
            webView.responds(to: NSSelectorFromString("_close"))
                && webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
            "This WebKit no longer answers to the private page calls"
        )
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<!doctype html><p>Discard me</p>", baseURL: nil)
        await fulfillment(of: [navigation.finished], timeout: 5)
        let processID = try XCTUnwrap((webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        XCTAssertGreaterThan(processID, 0)

        WebViewPool.shared.discard(tab.id)

        // A page that lets go of its process reports none. Whether the process itself has
        // exited cannot be asked from here: the sandbox answers `kill(pid, 0)` with a refusal
        // for a live process and a dead one alike.
        XCTAssertEqual((webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, 0, "the page is still open")
    }

    /// Chat and Calendar read the permission through `navigator.permissions` before their own
    /// first post, so an allowed origin has to read `granted` there from document start.
    @MainActor
    func testAllowedOriginSeesGrantedNotificationsFromDocumentStart() async throws {
        let origin = "https://notify.jungle.test"
        SitePermissions.remember(true, for: origin, kinds: [.notifications])
        defer { SitePermissions.forget([.notifications], for: origin) }
        let dataStoreID = try XCTUnwrap(UUID(uuidString: "6A0C7E52-1D3B-4F4B-9C55-7A1E0D2B9F10"))
        let profile = BrowserProfile(name: "Notify", symbol: "person", tint: .green, dataStoreID: dataStoreID)
        let tab = BrowserTab(profileID: profile.id)
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        defer { WebViewPool.shared.discard(tab.id) }
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<!doctype html><script>window.firstRead = Notification.permission;</script>",
            baseURL: URL(string: origin)
        )
        await fulfillment(of: [navigation.finished], timeout: 5)

        let result = try await webView.callAsyncJavaScript(
            """
            const status = await navigator.permissions.query({ name: 'notifications' });
            return [window.firstRead, status.state,
                    typeof ServiceWorkerRegistration === 'undefined' ? 'none'
                        : String(ServiceWorkerRegistration.prototype.showNotification).includes('JungleNotification') ? 'jungle' : 'native'];
            """,
            contentWorld: .page
        )
        let values = try XCTUnwrap(result as? [String])
        XCTAssertEqual(values[0], "granted")
        XCTAssertEqual(values[1], "granted")
        XCTAssertNotEqual(values[2], "native", "registration.showNotification still goes to WebKit")
    }
}

@MainActor
private final class NavigationCompletion: NSObject, WKNavigationDelegate {
    let finished = XCTestExpectation(description: "Web view finished loading")

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
}

private final class GrantingCapturePermissions: NSObject, WKUIDelegate {
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func requestDisplayCapturePermission(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        withSystemAudio: Bool,
        decisionHandler: @escaping (Int) -> Void
    ) { decisionHandler(1) }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) { decisionHandler(.grant) }
}

private final class PageKeyMessages: NSObject, WKScriptMessageHandler {
    private(set) var count = 0

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        count += 1
    }
}

private final class DiscardedMessages: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
