import AppKit
import Combine
import Foundation
import WebKit

@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var profiles: [BrowserProfile]
    @Published private(set) var tabs: [BrowserTab]
    @Published var selectedTabID: UUID?
    @Published var activeProfileID: UUID
    @Published var isCommandPalettePresented = false
    @Published var isSettingsPresented = false
    @Published var isHistoryPresented = false
    @Published var isDownloadsPresented = false
    @Published var isSidebarVisible = true
    @Published private(set) var tabPreviewID: UUID?
    @Published private(set) var loadingTabIDs: Set<UUID> = []
    @Published private(set) var closingTabIDs: Set<UUID> = []
    @Published private(set) var copiedTabAddress: URL?
    @Published private(set) var copiedScreenshotTabID: UUID?
    /// The zoom just applied to the selected tab, while its badge is on screen. `nil` hides it.
    @Published private(set) var pageZoomFeedback: Double?
    /// The failure each tab's last navigation ended in, for as long as nothing has loaded over it.
    @Published private(set) var navigationFailures: [UUID: NavigationFailure] = [:]
    @Published private(set) var developerMetricsByTabID: [UUID: DeveloperMetrics] = [:]
    @Published private(set) var initialContentReadyTabIDs: Set<UUID> = []
    @Published private(set) var audibleTabIDs: Set<UUID> = []
    @Published private(set) var mutedTabIDs: Set<UUID> = []
    /// The tab whose video WebKit is showing in its floating window.
    @Published private(set) var pictureInPictureTabID: UUID?
    /// The tab we just asked for Picture in Picture. Its web view has to stay in the window
    /// until the page answers, because WebKit tears the floating window down the moment the
    /// view that owns the video leaves the window.
    @Published private(set) var pictureInPictureRequestTabID: UUID?
    /// The find bar. Its own object, so typing in it redraws the bar and not the workspace.
    let findInPage = FindInPage()
    /// Quick Access opens a saved page in place instead of adding a row to the tab list:
    /// bookmark id to the tab it owns. Kept out of persistence, so a relaunch starts with
    /// every tile closed.
    @Published private(set) var quickAccessTabIDs: [UUID: UUID] = [:]
    @Published private(set) var bookmarkFolders: [BookmarkFolder]
    @Published private(set) var history: [BrowsingHistoryEntry]
    @Published private(set) var downloads: [BrowserDownload]
    @Published private(set) var extensions: [BrowserExtension]
    @Published private(set) var isExtensionImporting = false
    @Published private(set) var extensionImportError: String?

    let settings: BrowserSettings
    private let persistence: BrowserPersistence
    private let extensionRuntime: ChromeDeclarativeExtensionRuntime
    private var housekeepingTask: Task<Void, Never>?
    private var tabPreviewTask: Task<Void, Never>?
    private var copiedAddressFeedbackTask: Task<Void, Never>?
    private var copiedScreenshotFeedbackTask: Task<Void, Never>?
    private var pageZoomFeedbackTask: Task<Void, Never>?
    private var closingTabTasks: [UUID: Task<Void, Never>] = [:]
    /// One per tab awaiting its reveal deadline: see `scheduleInitialContentRevealDeadline`.
    private var revealDeadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var audioObserver: AnyCancellable?
    private var firstContentfulPaintObserver: AnyCancellable?
    private var persistWorkspaceTask: Task<Void, Never>?
    private var terminationObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var previouslySelectedTabID: UUID?
    private var lastRequestedAddresses: [UUID: URL] = [:]

    init(settings: BrowserSettings? = nil, persistence: BrowserPersistence? = nil) {
        let resolvedPersistence = persistence ?? BrowserPersistence.shared
        self.persistence = resolvedPersistence
        let resolvedExtensionRuntime = ChromeDeclarativeExtensionRuntime.shared
        self.extensionRuntime = resolvedExtensionRuntime
        let browserSettings = settings ?? BrowserSettings(persistence: resolvedPersistence)
        self.settings = browserSettings
        let browserProfiles = resolvedPersistence.loadProfiles()
        let firstTab = BrowserTab(profileID: browserProfiles[0].id, address: browserSettings.newTabURL)
        let workspace = resolvedPersistence.loadWorkspace(profiles: browserProfiles)
        profiles = browserProfiles
        tabs = workspace?.tabs ?? [firstTab]
        activeProfileID = browserProfiles[workspace?.activeProfileSlot ?? 0].id
        selectedTabID = workspace?.selectedTabID ?? firstTab.id
        bookmarkFolders = resolvedPersistence.loadBookmarks(for: browserProfiles)
        history = resolvedPersistence.loadHistory()
        downloads = resolvedPersistence.loadDownloads()
        extensions = resolvedExtensionRuntime.extensions
        settingsObserver = browserSettings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // The workspace write is coalesced, so the last change needs a flush before the app goes.
        terminationObserver = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.persistWorkspaceTask?.cancel()
                    self.persistence.saveWorkspace(
                        tabs: self.persistableTabs,
                        profiles: self.profiles,
                        activeProfileID: self.activeProfileID,
                        selectedTabID: self.selectedTabID
                    )
                }
            }
        audioObserver = NotificationCenter.default
            .publisher(for: .jungleAudioDidChange)
            .sink { [weak self] notification in
                guard let tabID = notification.userInfo?["tabID"] as? UUID,
                      let isAudible = notification.userInfo?["isAudible"] as? Bool
                else { return }
                Task { @MainActor [weak self] in
                    self?.audioDidChange(isAudible: isAudible, for: tabID)
                }
            }
        firstContentfulPaintObserver = NotificationCenter.default
            .publisher(for: .jungleFirstContentfulPaint)
            .sink { [weak self] notification in
                guard let tabID = notification.userInfo?["tabID"] as? UUID else { return }
                Task { @MainActor [weak self] in
                    self?.didPaintFirstContent(for: tabID)
                }
            }
        resolvedExtensionRuntime.start()
    }

    deinit {
        housekeepingTask?.cancel()
        tabPreviewTask?.cancel()
        copiedAddressFeedbackTask?.cancel()
        copiedScreenshotFeedbackTask?.cancel()
        pageZoomFeedbackTask?.cancel()
        closingTabTasks.values.forEach { $0.cancel() }
        revealDeadlineTasks.values.forEach { $0.cancel() }
        persistWorkspaceTask?.cancel()
    }

    var activeProfile: BrowserProfile { profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0] }
    var selectedTab: BrowserTab? { tabs.first(where: { $0.id == selectedTabID }) }
    var selectedTabAddressText: String { selectedTab?.isNativeNewTab == true ? "" : selectedTab?.address.absoluteString ?? "" }
    var visibleTabs: [BrowserTab] { tabs.filter { $0.profileID == activeProfileID } }
    /// The tabs the sidebar lists. A tab a Quick Access tile owns lives on its tile instead,
    /// and comes back to the list if its saved page ever leaves Quick Access.
    var listedTabs: [BrowserTab] { visibleTabs.filter { !quickAccessTabIDSet.contains($0.id) } }
    private var quickAccessTabIDSet: Set<UUID> {
        let bookmarkIDs = Set(bookmarkFolders.filter(\.isQuickAccess).flatMap(\.bookmarks).map(\.id))
        return Set(quickAccessTabIDs.filter { bookmarkIDs.contains($0.key) }.values)
    }
    var visibleHistory: [BrowsingHistoryEntry] { history.filter { $0.profileID == activeProfileID } }
    var visibleDownloads: [BrowserDownload] { downloads.filter { $0.profileID == activeProfileID } }
    var visibleBookmarkFolders: [BookmarkFolder] { bookmarkFolders.filter { $0.profileID == activeProfileID } }
    /// The Quick Access tiles in the order the sidebar shows them, which is the order ⌘1…⌘9
    /// address: the first tile is ⌘1, and reordering the tiles reorders the shortcuts with it.
    var quickAccessBookmarks: [BrowserBookmark] { visibleBookmarkFolders.first(where: \.isQuickAccess)?.bookmarks ?? [] }
    /// The tab that keeps its web view attached to the window even while another tab is on
    /// screen, so its floating window survives the switch.
    var pictureInPictureHoldTabID: UUID? { pictureInPictureTabID ?? pictureInPictureRequestTabID }
    var isSelectedTabLoading: Bool { selectedTabID.map { loadingTabIDs.contains($0) } ?? false }
    var selectedNavigationFailure: NavigationFailure? { selectedTabID.flatMap { navigationFailures[$0] } }
    var selectedTabInitialContentIsReady: Bool { selectedTabID.map { initialContentReadyTabIDs.contains($0) } ?? false }
    var selectedTabUsesInsecureHTTP: Bool { selectedTab.map { BrowserAddress.usesInsecureHTTP($0.address) } ?? false }
    var selectedTabIsLocalDevelopment: Bool { selectedTab.map { BrowserAddress.isLocalDevelopmentURL($0.address) } ?? false }
    var selectedDeveloperMetrics: DeveloperMetrics? {
        guard let selectedTabID else { return nil }
        return developerMetricsByTabID[selectedTabID]
    }

    func beginMemoryHousekeeping() {
        guard housekeepingTask == nil else { return }
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.discardIdleTabs()
            }
        }
    }

    func createTab() {
        let tab = BrowserTab(profileID: activeProfileID, address: settings.newTabURL)
        tabs.append(tab)
        select(tab.id)
    }

    func select(_ tabID: UUID, entersPictureInPictureWhenLeaving: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let previousTabID = selectedTabID
        // Leaving a tab that is playing video sends it to Picture in Picture, the way
        // Safari does. The floating window keeps its own control to return it inline.
        if entersPictureInPictureWhenLeaving, pictureInPictureTabID == nil,
           let previousTabID, previousTabID != tabID, tabs.contains(where: { $0.id == previousTabID }) {
            requestPictureInPicture(for: previousTabID)
        }
        activeProfileID = tabs[index].profileID
        selectedTabID = tabID
        if previousTabID != tabID {
            // Find belongs to the page it searched, like the zoom badge below.
            findInPage.dismiss()
            // The badge belongs to the tab it was raised over, not to the one arriving.
            pageZoomFeedbackTask?.cancel()
            pageZoomFeedback = nil
            previouslySelectedTabID = previousTabID
            // Idle time is measured from when a tab stopped being selected, not from when it
            // was last selected: stamping only the arriving tab left the one being left behind
            // with a stale timestamp, so `discardIdleTabs` could suspend a tab the user had just
            // spent twenty minutes reading, seconds after they switched away from it.
            if let previousTabID, let previousIndex = tabs.firstIndex(where: { $0.id == previousTabID }) {
                tabs[previousIndex].lastActivatedAt = .now
            }
        }
        tabs[index].lastActivatedAt = .now
        tabs[index].isSuspended = false
        persistWorkspace()
    }

    func close(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        closingTabTasks.removeValue(forKey: tabID)?.cancel()
        closingTabIDs.remove(tabID)
        let profileID = tabs[index].profileID
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: index)
        loadingTabIDs.remove(tabID)
        initialContentReadyTabIDs.remove(tabID)
        cancelInitialContentRevealDeadline(for: tabID)
        lastRequestedAddresses.removeValue(forKey: tabID)
        lastScriptedPopupDates.removeValue(forKey: tabID)
        developerMetricsByTabID.removeValue(forKey: tabID)
        audibleTabIDs.remove(tabID)
        mutedTabIDs.remove(tabID)
        quickAccessTabIDs = quickAccessTabIDs.filter { $0.value != tabID }
        if copiedScreenshotTabID == tabID { copiedScreenshotTabID = nil }
        navigationFailures.removeValue(forKey: tabID)
        releasePictureInPicture(for: tabID)
        if findInPage.tabID == tabID { findInPage.dismiss() }
        WebViewPool.shared.discard(tabID)
        guard wasSelected else {
            persistWorkspace()
            return
        }
        if let replacement = tabs.last(where: { $0.profileID == profileID }) {
            select(replacement.id)
        } else {
            activeProfileID = profileID
            createTab()
        }
    }

    func closeSelectedTab() {
        guard let selectedTabID else { return }
        requestClose(selectedTabID)
    }

    func requestClose(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }), !closingTabIDs.contains(tabID) else { return }
        closingTabIDs.insert(tabID)
        closingTabTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.close(tabID)
        }
    }

    func isClosingTab(_ tabID: UUID) -> Bool {
        closingTabIDs.contains(tabID)
    }

    func switchProfile(to profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        activeProfileID = profileID
        if let latest = tabs.filter({ $0.profileID == profileID }).max(by: { $0.lastActivatedAt < $1.lastActivatedAt }) {
            select(latest.id)
        } else {
            createTab()
        }
    }

    func switchProfile(number: Int) {
        guard profiles.indices.contains(number - 1) else { return }
        switchProfile(to: profiles[number - 1].id)
    }

    func createProfile() {
        let tint = ProfileTint.allCases[profiles.count % ProfileTint.allCases.count]
        let profile = BrowserProfile(name: "Profile \(profiles.count + 1)", symbol: "person.crop.circle", tint: tint)
        profiles.append(profile)
        bookmarkFolders.append(contentsOf: BookmarkFolder.defaults(for: profile.id))
        persistProfiles()
        persistBookmarks()
        switchProfile(to: profile.id)
    }

    func renameProfile(_ profileID: UUID, to name: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        updateProfile(profileID, name: name, symbol: profile.symbol, tint: profile.tint)
    }

    func updateProfile(_ profileID: UUID, name: String, symbol: String, tint: ProfileTint) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let profile = profiles[index]
        profiles[index] = BrowserProfile(id: profile.id, name: trimmedName, symbol: symbol, tint: tint, dataStoreID: profile.dataStoreID)
        persistProfiles()
    }

    func deleteProfile(_ profileID: UUID) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let removedTabs = tabs.filter { $0.profileID == profileID }
        removedTabs.forEach {
            lastRequestedAddresses.removeValue(forKey: $0.id)
            WebViewPool.shared.discard($0.id)
        }
        tabs.removeAll { $0.profileID == profileID }
        quickAccessTabIDs = quickAccessTabIDs.filter { entry in tabs.contains(where: { $0.id == entry.value }) }
        bookmarkFolders.removeAll { $0.profileID == profileID }
        profiles.remove(at: index)
        if activeProfileID == profileID {
            activeProfileID = profiles[0].id
        }
        if !tabs.contains(where: { $0.profileID == activeProfileID }) {
            let tab = BrowserTab(profileID: activeProfileID, address: settings.newTabURL)
            tabs.append(tab)
            selectedTabID = tab.id
        } else if let selectedID = selectedTabID, !tabs.contains(where: { $0.id == selectedID }) {
            selectedTabID = tabs.first(where: { $0.profileID == activeProfileID })?.id
        }
        persistProfiles()
        persistBookmarks()
        persistWorkspace()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func importChromeExtension() {
        extensionImportError = nil
        let panel = NSOpenPanel()
        panel.title = "Import Chrome extension"
        panel.message = "Choose the unpacked folder that contains manifest.json."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.installChromeExtension(from: directory)
            }
        }
    }

    func setExtensionEnabled(_ isEnabled: Bool, for extensionID: UUID) {
        guard let index = extensions.firstIndex(where: { $0.id == extensionID }) else { return }
        extensions[index].isEnabled = isEnabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.extensionRuntime.setEnabled(isEnabled, for: extensionID)
            self.extensions = self.extensionRuntime.extensions
        }
    }

    func removeExtension(_ extensionID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.extensionRuntime.remove(extensionID)
            self.extensions = self.extensionRuntime.extensions
        }
    }

    func navigate(to input: String) {
        guard let destination = BrowserAddress.resolve(input, using: settings.searchEngine), let tabID = selectedTabID else { return }
        update(tabID) { tab in
            tab.address = destination
            tab.title = destination.host ?? destination.absoluteString
            tab.isSuspended = false
            tab.preview = nil
        }
        loadSelectedTabIfNeeded(force: true)
    }

    func openExternalURL(_ url: URL) {
        guard BrowserAddress.isWebURL(url) else { return }
        navigate(to: url.absoluteString)
    }

    func reloadSelectedTab() {
        guard let tab = selectedTab, let webView = loadedWebView(for: tab) else { return }
        // A failed load leaves the web view holding no document, and `reload` on nothing does
        // nothing — which is what left the error page with a button that did not work.
        guard webView.url != nil else {
            navigationFailures.removeValue(forKey: tab.id)
            lastRequestedAddresses[tab.id] = tab.address
            webView.load(URLRequest(url: tab.address))
            return
        }
        webView.reload()
    }
    func reloadSelectedTabIgnoringCache() { loadedWebView(for: selectedTab)?.reloadFromOrigin() }

    func togglePictureInPicture() {
        // The floating window is driven from wherever the user is, not only from its own tab.
        if let tabID = pictureInPictureHoldTabID {
            Task { [weak self] in
                guard await WebViewPool.shared.exitPictureInPicture(for: tabID) == false, let self else { return }
                // Nothing was floating after all: drop the stale hold and start a session here.
                self.releasePictureInPicture(for: tabID)
                if let selectedTabID = self.selectedTabID { self.requestPictureInPicture(for: selectedTabID) }
            }
            return
        }
        guard let selectedTabID else { return }
        requestPictureInPicture(for: selectedTabID)
    }

    func pictureInPictureDidChange(isActive: Bool, tabID: UUID) {
        guard isActive else {
            guard pictureInPictureHoldTabID == tabID else { return }
            let wasFloating = pictureInPictureTabID == tabID
            pictureInPictureTabID = nil
            pictureInPictureRequestTabID = nil
            if wasFloating { restoreTabFromPictureInPicture(tabID) }
            return
        }
        pictureInPictureTabID = tabID
        pictureInPictureRequestTabID = nil
    }

    func restoreTabFromPictureInPicture(_ tabID: UUID) {
        if pictureInPictureHoldTabID == tabID {
            pictureInPictureTabID = nil
            pictureInPictureRequestTabID = nil
        }
        guard selectedTabID != tabID, tabs.contains(where: { $0.id == tabID }) else { return }
        // Returning one PiP window inline must not put media from the current tab in PiP.
        select(tabID, entersPictureInPictureWhenLeaving: false)
    }

    /// ⌘F. Only a page that is loaded has anything to search.
    func presentFindInPage() {
        guard let tab = selectedTab, let webView = loadedWebView(for: tab) else { return }
        findInPage.present(tabID: tab.id, webView: webView)
    }

    /// Escape or Done: the keyboard goes back to the page, so Space scrolls it again.
    func dismissFindInPage() {
        let webView = loadedWebView(for: selectedTab)
        findInPage.dismiss()
        webView?.window?.makeFirstResponder(webView)
    }

    func toggleWebInspector() {
        guard let webView = loadedWebView(for: selectedTab) else { return }
        WebInspector.toggle(for: webView)
    }

    func showJavaScriptConsole() {
        guard let webView = loadedWebView(for: selectedTab) else { return }
        WebInspector.showConsole(for: webView)
    }

    func stopLoadingSelectedTab() {
        guard let tabID = selectedTabID else { return }
        loadedWebView(for: selectedTab)?.stopLoading()
        loadingTabIDs.remove(tabID)
    }

    /// The tab a Quick Access tile is showing right now, or `nil` when the tile is closed.
    func quickAccessTabID(for bookmarkID: UUID) -> UUID? {
        guard let tabID = quickAccessTabIDs[bookmarkID], tabs.contains(where: { $0.id == tabID }) else { return nil }
        return tabID
    }

    func isQuickAccessBookmarkActive(_ bookmarkID: UUID) -> Bool {
        guard let tabID = quickAccessTabID(for: bookmarkID) else { return false }
        return tabID == selectedTabID
    }

    /// Opens the saved page on its own tile rather than in a new row of the tab list. A tile
    /// that is already open is selected again instead of opening a second copy.
    func openQuickAccessBookmark(_ bookmark: BrowserBookmark) {
        if let tabID = quickAccessTabID(for: bookmark.id) {
            select(tabID)
            return
        }
        let tab = BrowserTab(profileID: activeProfileID, address: bookmark.address, title: bookmark.title)
        tabs.append(tab)
        quickAccessTabIDs[bookmark.id] = tab.id
        select(tab.id)
    }

    /// Opens the tile at `number`, counting from 1. A number with no tile behind it does
    /// nothing, so ⌘7 on four tiles is a keystroke that misses rather than a surprise.
    func openQuickAccessBookmark(number: Int) {
        guard number >= 1, let bookmark = quickAccessBookmarks.dropFirst(number - 1).first else { return }
        openQuickAccessBookmark(bookmark)
    }

    func closeQuickAccessBookmark(_ bookmarkID: UUID) {
        guard let tabID = quickAccessTabID(for: bookmarkID) else { return }
        close(tabID)
    }

    func openBookmark(_ bookmark: BrowserBookmark) {
        let tab = BrowserTab(
            profileID: activeProfileID,
            address: bookmark.address,
            title: bookmark.title
        )
        tabs.append(tab)
        select(tab.id)
    }

    /// The address a `target="_blank"` link may open a tab for. A link that is itself a
    /// download gets none: WebKit downloads it from the page that asked, and a tab opened
    /// beside it fetches the same file again and then sits blank forever.
    static func newWindowDestination(shouldPerformDownload: Bool, requestURL: URL?) -> URL? {
        guard !shouldPerformDownload, let requestURL, BrowserAddress.isWebURL(requestURL) else { return nil }
        return requestURL
    }

    /// How long a tab has to wait before a script may open a second window. A burst of
    /// `window.open` calls inside one click is the whole popup-flood technique, and WebKit's
    /// gesture requirement does not bound it: every call in that handler carries the gesture.
    nonisolated static let scriptedPopupInterval: TimeInterval = 1

    /// Whether this tab may open one more window right now.
    ///
    /// An embedded frame from another site never gets one. A video player, an ad slot, or any
    /// third-party widget asking for a window is asking on its own behalf, not the user's:
    /// the click that reached it was meant for the thing it is embedded as. This is the whole
    /// popunder technique on streaming sites, and it is the one case a filter list cannot
    /// reach, because the frame opening the window is the content the user came for and its
    /// destinations are fresh throwaway domains.
    ///
    /// Everything the page itself asks for is judged as before. A link the user clicked always
    /// opens: a second click is a second decision, and answering `nil` to one tells the page
    /// its popup was blocked, which is what makes a page run the download fallback it has.
    /// Only scripted windows are spaced out, so the first of a burst still opens and the rest
    /// do not.
    nonisolated static func shouldAllowPopup(
        isFromEmbeddedOtherSiteFrame: Bool,
        isLinkActivated: Bool,
        lastScriptedPopupAt: Date?,
        now: Date = .now
    ) -> Bool {
        // Checked before the clicked-link allowance on purpose: these players put a bare
        // `target="_blank"` anchor over the picture, so the ad arrives as a link click.
        if isFromEmbeddedOtherSiteFrame { return false }
        if isLinkActivated { return true }
        guard let lastScriptedPopupAt else { return true }
        return now.timeIntervalSince(lastScriptedPopupAt) >= scriptedPopupInterval
    }

    /// Whether a frame belongs to the site the tab is showing. Hosts under one another count
    /// as the same site, so a page embedding its own player keeps the windows it opens.
    nonisolated static func isSameSite(frameHost: String?, pageHost: String?) -> Bool {
        guard let frameHost = frameHost?.lowercased(), let pageHost = pageHost?.lowercased(),
              !frameHost.isEmpty, !pageHost.isEmpty else { return false }
        if frameHost == pageHost { return true }
        return frameHost.hasSuffix("." + pageHost) || pageHost.hasSuffix("." + frameHost)
    }

    /// The instant this tab last opened a scripted window, which is what spaces the next one out.
    private var lastScriptedPopupDates: [UUID: Date] = [:]

    func allowsPopup(from sourceTabID: UUID, isFromEmbeddedOtherSiteFrame: Bool, isLinkActivated: Bool) -> Bool {
        guard Self.shouldAllowPopup(
            isFromEmbeddedOtherSiteFrame: isFromEmbeddedOtherSiteFrame && settings.adBlocking.blocksEmbeddedPlayerPopups,
            isLinkActivated: isLinkActivated,
            lastScriptedPopupAt: lastScriptedPopupDates[sourceTabID]
        ) else { return false }
        if !isLinkActivated { lastScriptedPopupDates[sourceTabID] = .now }
        return true
    }

    /// Closes a tab that only ever existed to carry a download. Its web view never receives a
    /// document, so leaving it open is a blank tab the user has to clean up.
    func closeTabOpenedForDownload(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        close(tabID)
    }

    /// The tab a page opened with `window.open` or a `target="_blank"` link. WebKit navigates
    /// the web view it was handed, so the address is recorded as already requested: loading it
    /// again here is a second request for the same file, which is a second download whenever
    /// that file is an attachment.
    func openPopupTab(from sourceTabID: UUID, address: URL) -> UUID? {
        guard BrowserAddress.isWebURL(address),
              let sourceTab = tabs.first(where: { $0.id == sourceTabID })
        else { return nil }
        let tab = BrowserTab(
            profileID: sourceTab.profileID,
            address: address,
            title: address.host ?? address.absoluteString
        )
        tabs.append(tab)
        lastRequestedAddresses[tab.id] = address
        select(tab.id)
        return tab.id
    }

    func openLinkInNewTab(_ address: URL, from sourceTabID: UUID) {
        guard BrowserAddress.isWebURL(address),
              let sourceTab = tabs.first(where: { $0.id == sourceTabID })
        else { return }
        let tab = BrowserTab(
            profileID: sourceTab.profileID,
            address: address,
            title: address.host ?? address.absoluteString
        )
        tabs.append(tab)
        select(tab.id)
    }

    func openHistoryEntry(_ entry: BrowsingHistoryEntry) {
        guard entry.profileID == activeProfileID else { return }
        navigate(to: entry.address.absoluteString)
    }

    func openHistoryEntryInNewTab(_ entry: BrowsingHistoryEntry) {
        guard entry.profileID == activeProfileID else { return }
        let tab = BrowserTab(profileID: activeProfileID, address: entry.address, title: entry.title)
        tabs.append(tab)
        select(tab.id)
    }

    func deleteHistoryEntry(_ entryID: UUID) {
        history.removeAll { $0.id == entryID }
        persistence.deleteHistoryEntry(entryID)
    }

    func clearHistory() {
        history.removeAll { $0.profileID == activeProfileID }
        persistence.deleteHistory(for: activeProfileID)
    }

    func beginDownload(for tabID: UUID, sourceAddress: URL, suggestedFileName: String? = nil) -> UUID {
        let profileID = tabs.first(where: { $0.id == tabID })?.profileID ?? activeProfileID
        let suggestedName = suggestedFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileName = suggestedName.isEmpty ? sourceAddress.lastPathComponent : suggestedName
        let download = BrowserDownload(
            profileID: profileID,
            sourceAddress: sourceAddress,
            fileName: fileName.isEmpty ? "Download" : fileName
        )
        downloads.insert(download, at: 0)
        persistence.saveDownload(download)
        return download.id
    }

    func prepareDownloadDestination(for downloadID: UUID, suggestedFileName: String, expectedBytes: Int64?) -> URL? {
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else { return nil }
        let fileName = sanitizedFileName(suggestedFileName)
        guard let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let destination = availableDestination(for: fileName, in: downloadsDirectory)
        downloads[index].fileName = destination.lastPathComponent
        downloads[index].destination = destination
        downloads[index].expectedBytes = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
        persistence.saveDownload(downloads[index])
        return destination
    }

    func recordDownloadData(_ byteCount: Int64, for downloadID: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else { return }
        downloads[index].receivedBytes += byteCount
    }

    func finishDownload(_ downloadID: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else { return }
        downloads[index].state = .completed
        downloads[index].completedAt = .now
        downloads[index].failureDescription = nil
        persistence.saveDownload(downloads[index])
    }

    func failDownload(_ downloadID: UUID, errorDescription: String) {
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else { return }
        downloads[index].state = .failed
        downloads[index].completedAt = .now
        downloads[index].failureDescription = errorDescription
        persistence.saveDownload(downloads[index])
    }

    func deleteDownload(_ downloadID: UUID) {
        downloads.removeAll { $0.id == downloadID }
        persistence.deleteDownload(downloadID)
    }

    func clearDownloads() {
        downloads.removeAll { $0.profileID == activeProfileID }
        persistence.deleteDownloads(for: activeProfileID)
    }

    func addressSuggestions(for input: String) -> [AddressSuggestion] {
        Self.rankedAddressSuggestions(
            for: input,
            tabs: visibleTabs,
            bookmarks: visibleBookmarkFolders.flatMap(\.bookmarks),
            history: visibleHistory
        )
    }

    func smartAddressSuggestions(for input: String) -> [SmartAddressSuggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let directURL = BrowserAddress.directWebURL(from: query)
        var suggestions: [SmartAddressSuggestion] = directURL.map { [.direct($0)] } ?? [.search(query: query, engine: settings.searchEngine)]
        suggestions.append(
            contentsOf: addressSuggestions(for: query)
                .filter { $0.address != directURL }
                .map(SmartAddressSuggestion.saved)
        )
        return suggestions
    }

    func saveCurrentPage(to folderID: UUID) {
        guard let selectedTabID else { return }
        saveTab(selectedTabID, to: folderID)
    }

    /// Reorders only the current profile's tabs, leaving other profiles at their existing
    /// positions in the persisted workspace. This makes a sidebar drag independent from
    /// WebKit: no view is created, selected, or retained while rows move.
    func moveTab(_ tabID: UUID, before destinationTabID: UUID?, persists: Bool = true) {
        guard let source = tabs.first(where: { $0.id == tabID }),
              source.profileID == activeProfileID
        else { return }
        if let destinationTabID,
           let destination = tabs.first(where: { $0.id == destinationTabID }),
           (destination.profileID != source.profileID || destination.isPinned != source.isPinned) {
            return
        }

        var profileTabs = tabs.filter { $0.profileID == source.profileID && $0.isPinned == source.isPinned }
        guard let sourceIndex = profileTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let movingTab = profileTabs.remove(at: sourceIndex)
        let destinationIndex = destinationTabID.flatMap { targetID in
            profileTabs.firstIndex(where: { $0.id == targetID })
        } ?? profileTabs.endIndex
        profileTabs.insert(movingTab, at: destinationIndex)

        var nextIndex = 0
        for index in tabs.indices where tabs[index].profileID == source.profileID && tabs[index].isPinned == source.isPinned {
            tabs[index] = profileTabs[nextIndex]
            nextIndex += 1
        }
        if persists { persistWorkspace() }
    }

    func finishTabDrag() {
        persistWorkspace()
    }

    @discardableResult
    func saveTab(_ tabID: UUID, to folderID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.profileID == activeProfileID,
              let index = bookmarkFolders.firstIndex(where: { $0.id == folderID && $0.profileID == activeProfileID }),
              !bookmarkFolders[index].bookmarks.contains(where: { $0.address == tab.address })
        else { return false }
        let bookmark = BrowserBookmark(title: tab.title, address: tab.address, symbol: bookmarkSymbol(for: tab.address))
        bookmarkFolders[index].bookmarks.append(bookmark)
        persistBookmarks()
        return true
    }

    /// Moves a saved page without recreating it, preserving its stable identity for SwiftUI.
    /// A `persists: false` move is used only while a pointer crosses rows; the final drop
    /// performs one SwiftData write.
    func moveBookmark(
        _ bookmarkID: UUID,
        from sourceFolderID: UUID,
        to destinationFolderID: UUID,
        before destinationBookmarkID: UUID? = nil,
        persists: Bool = true
    ) {
        guard let sourceFolderIndex = bookmarkFolders.firstIndex(where: { $0.id == sourceFolderID && $0.profileID == activeProfileID }),
              let destinationFolderIndex = bookmarkFolders.firstIndex(where: { $0.id == destinationFolderID && $0.profileID == activeProfileID }),
              let bookmarkIndex = bookmarkFolders[sourceFolderIndex].bookmarks.firstIndex(where: { $0.id == bookmarkID })
        else { return }

        let bookmark = bookmarkFolders[sourceFolderIndex].bookmarks.remove(at: bookmarkIndex)
        let resolvedDestinationIndex = bookmarkFolders.firstIndex(where: { $0.id == destinationFolderID }) ?? destinationFolderIndex
        var destinationBookmarks = bookmarkFolders[resolvedDestinationIndex].bookmarks
        let insertionIndex = destinationBookmarkID.flatMap { targetID in
            destinationBookmarks.firstIndex(where: { $0.id == targetID })
        } ?? destinationBookmarks.endIndex
        destinationBookmarks.insert(bookmark, at: insertionIndex)
        bookmarkFolders[resolvedDestinationIndex].bookmarks = destinationBookmarks

        if persists { persistBookmarks() }
    }

    func finishBookmarkDrag() {
        persistBookmarks()
    }

    func createBookmarkFolder(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        bookmarkFolders.append(BookmarkFolder(profileID: activeProfileID, name: trimmedName))
        persistBookmarks()
    }

    /// `nil` hands the tile back to the site's favicon.
    func setBookmarkSymbol(_ symbol: String?, for bookmarkID: UUID, in folderID: UUID) {
        guard let folderIndex = bookmarkFolders.firstIndex(where: { $0.id == folderID && $0.profileID == activeProfileID }),
              let bookmarkIndex = bookmarkFolders[folderIndex].bookmarks.firstIndex(where: { $0.id == bookmarkID })
        else { return }
        bookmarkFolders[folderIndex].bookmarks[bookmarkIndex].customSymbol = symbol
        persistBookmarks()
    }

    func deleteBookmark(_ bookmarkID: UUID, from folderID: UUID) {
        guard let index = bookmarkFolders.firstIndex(where: { $0.id == folderID && $0.profileID == activeProfileID }) else { return }
        bookmarkFolders[index].bookmarks.removeAll { $0.id == bookmarkID }
        persistBookmarks()
    }

    func deleteFolder(_ folderID: UUID) {
        guard let index = bookmarkFolders.firstIndex(where: { $0.id == folderID && $0.profileID == activeProfileID }) else { return }
        bookmarkFolders.remove(at: index)
        persistBookmarks()
    }

    func toggleFolder(_ folderID: UUID) {
        guard let index = bookmarkFolders.firstIndex(where: { $0.id == folderID && $0.profileID == activeProfileID }) else { return }
        bookmarkFolders[index].isExpanded.toggle()
        persistBookmarks()
    }
    func goBack() { if let view = loadedWebView(for: selectedTab), view.canGoBack { view.goBack() } }
    func goForward() { if let view = loadedWebView(for: selectedTab), view.canGoForward { view.goForward() } }
    func zoomIn() { applyPageZoom { Self.pageZoomStep(above: $0) } }
    func zoomOut() { applyPageZoom { Self.pageZoomStep(below: $0) } }
    func resetPageZoom() { applyPageZoom { _ in 1 } }

    /// The ladder Safari and Chrome step through. Clamped at both ends: a page that cannot
    /// grow any further still shows its badge, which is how the user learns it is at the top.
    static let pageZoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func pageZoomStep(above level: Double) -> Double {
        pageZoomSteps.first(where: { $0 > level + 0.001 }) ?? pageZoomSteps[pageZoomSteps.count - 1]
    }

    static func pageZoomStep(below level: Double) -> Double {
        pageZoomSteps.last(where: { $0 < level - 0.001 }) ?? pageZoomSteps[0]
    }

    /// `pageZoom` reflows the document the way a browser's zoom does. `magnification` is the
    /// other WebKit knob and the wrong one: it scales the rendered pixels and goes soft.
    ///
    /// ponytail: the web view is the only store of a tab's zoom, so it lives as long as the
    /// tab and resets with a new tab. Persist per host when zoom should outlive the tab.
    private func applyPageZoom(_ nextLevel: (Double) -> Double) {
        guard let webView = loadedWebView(for: selectedTab) else { return }
        let level = nextLevel(webView.pageZoom)
        webView.pageZoom = level
        pageZoomFeedback = level
        pageZoomFeedbackTask?.cancel()
        pageZoomFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.pageZoomFeedback = nil
        }
    }

    func copySelectedTabAddress() {
        guard let address = selectedTab?.address, BrowserAddress.isWebURL(address) else { return }
        // What leaves the browser is the shareable link, not the one the campaign wrote.
        let shareable = BrowserAddress.withoutTrackingParameters(address)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(shareable.absoluteString, forType: .string) else { return }
        copiedTabAddress = shareable
        copiedAddressFeedbackTask?.cancel()
        copiedAddressFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedTabAddress = nil
        }
    }

    func copySelectedTabScreenshot() {
        guard let tabID = selectedTabID else { return }
        WebViewPool.shared.takeSnapshot(of: tabID) { [weak self] image in
            guard let pngData = Self.pngData(from: image) else { return }
            Task { @MainActor in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setData(pngData, forType: .png) else { return }
                self?.copiedScreenshotTabID = tabID
                self?.copiedScreenshotFeedbackTask?.cancel()
                self?.copiedScreenshotFeedbackTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.copiedScreenshotTabID = nil
                }
            }
        }
    }

    func refreshSelectedDeveloperMetrics() {
        guard let selectedTabID else { return }
        WebViewPool.shared.reportDeveloperMetrics(for: selectedTabID)
    }

    func recordDeveloperMetrics(_ metrics: DeveloperMetrics, for tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }), BrowserAddress.isLocalDevelopmentURL(metrics.pageURL) else { return }
        developerMetricsByTabID[tabID] = metrics
    }

    static func commandClickDestination(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        requestURL: URL?
    ) -> URL? {
        guard navigationType == .linkActivated,
              modifierFlags.contains(.command),
              let requestURL,
              BrowserAddress.isWebURL(requestURL)
        else { return nil }
        return requestURL
    }
    func togglePinned(_ tabID: UUID) { update(tabID) { $0.isPinned.toggle() } }

    func isAudible(_ tabID: UUID) -> Bool { audibleTabIDs.contains(tabID) }

    func isMuted(_ tabID: UUID) -> Bool { mutedTabIDs.contains(tabID) }

    func toggleMuted(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        let shouldMute = !mutedTabIDs.contains(tabID)
        if shouldMute { mutedTabIDs.insert(tabID) } else { mutedTabIDs.remove(tabID) }
        WebViewPool.shared.setMuted(shouldMute, in: tabID)
    }

    private func audioDidChange(isAudible: Bool, for tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if isAudible { audibleTabIDs.insert(tabID) } else { audibleTabIDs.remove(tabID) }
    }

    func didCommitNavigation(for tabID: UUID, url: URL?) {
        guard let url else { return }
        update(tabID) { $0.address = url }
        // An address the web view moved to on its own is an address it has already requested.
        // Leaving the pre-redirect one recorded made a tab whose response turned into a
        // download look like it had never loaded, and the next layout pass asked for the file
        // a second time: one click on a Jira attachment saved it twice.
        lastRequestedAddresses[tabID] = url
        // A committed document covers whatever failed before it, including the same-document
        // moves that never start a navigation. Otherwise the error page stays over a live page.
        navigationFailures.removeValue(forKey: tabID)
        scheduleInitialContentRevealDeadline(for: tabID)
    }

    /// First-contentful-paint is the primary signal for uncovering a tab, but a heavy page can
    /// take up to a minute to report it (or never does, for a resource that has no notion of
    /// paint). A committed navigation already has something in the web view, so a short bound
    /// keeps the opaque cover from hiding an already-painted page far past the point it matters.
    private func scheduleInitialContentRevealDeadline(for tabID: UUID) {
        guard !initialContentReadyTabIDs.contains(tabID) else { return }
        revealDeadlineTasks[tabID]?.cancel()
        revealDeadlineTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.revealDeadlineTasks.removeValue(forKey: tabID)
            guard self.tabs.contains(where: { $0.id == tabID && !$0.isSuspended }) else { return }
            self.initialContentReadyTabIDs.insert(tabID)
        }
    }

    /// Drops a pending reveal deadline without firing it, for a tab that closed, suspended, or
    /// lost its web content before the deadline had a reason to run.
    private func cancelInitialContentRevealDeadline(for tabID: UUID) {
        revealDeadlineTasks.removeValue(forKey: tabID)?.cancel()
    }

    func didStartNavigation(for tabID: UUID) {
        navigationFailures.removeValue(forKey: tabID)
        // A new document takes the video, and its floating window, with it.
        releasePictureInPicture(for: tabID)
        audibleTabIDs.remove(tabID)
        setNavigationLoading(true, for: tabID)
        developerMetricsByTabID.removeValue(forKey: tabID)
    }

    /// Uncovers the web view as soon as the document has painted. Load completion arrives much
    /// later on a content-heavy page — measured at 3.1s after first paint on a Wikipedia
    /// article — and keeping the cover up until then is what made navigation feel slow.
    func didPaintFirstContent(for tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID && !$0.isSuspended }) else { return }
        initialContentReadyTabIDs.insert(tabID)
    }

    func didFinishNavigation(for tabID: UUID, title: String?, url: URL?) {
        setNavigationLoading(false, for: tabID)
        findInPage.pageDidChange(in: tabID)
        navigationFailures.removeValue(forKey: tabID)
        // ponytail: still the reveal of last resort. A document that never reports a
        // contentful paint — a PDF, an image, an empty response — has no other signal.
        initialContentReadyTabIDs.insert(tabID)
        // A new document means a freshly injected script, which starts unmuted. This runs
        // ahead of the web-URL guard below: a tab resumed from suspension needs it too.
        if mutedTabIDs.contains(tabID) { WebViewPool.shared.setMuted(true, in: tabID) }
        update(tabID) { tab in
            if let url { tab.address = url }
            let candidate = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            tab.title = candidate.isEmpty ? (tab.address.host ?? tab.address.absoluteString) : candidate
        }
        guard let tab = tabs.first(where: { $0.id == tabID }), BrowserAddress.isWebURL(tab.address) else { return }
        let entry = BrowsingHistoryEntry(profileID: tab.profileID, title: tab.title, address: tab.address)
        history.insert(entry, at: 0)
        if history.count > Self.retainedHistoryCount { history.removeLast(history.count - Self.retainedHistoryCount) }
        persistence.saveHistoryEntry(entry)
        WebViewPool.shared.reportDeveloperMetrics(for: tabID)
    }

    func didFailNavigation(for tabID: UUID, error: Error) {
        setNavigationLoading(false, for: tabID)
        initialContentReadyTabIDs.insert(tabID)
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let failure = NavigationFailure(error: error, address: tab.address)
        else { return }
        navigationFailures[tabID] = failure
    }

    func didTerminateWebContent(for tabID: UUID) {
        releasePictureInPicture(for: tabID)
        audibleTabIDs.remove(tabID)
        setNavigationLoading(false, for: tabID)
        initialContentReadyTabIDs.remove(tabID)
        cancelInitialContentRevealDeadline(for: tabID)
        lastRequestedAddresses.removeValue(forKey: tabID)
        developerMetricsByTabID.removeValue(forKey: tabID)
        // The crashed process's web view still holds the old URL, so `loadSelectedTabIfNeeded`
        // would see a non-nil `url` and never reload it. Discarding it means the next attach
        // builds a fresh web view with no URL, which does load.
        WebViewPool.shared.discard(tabID)
    }

    func setNavigationLoading(_ isLoading: Bool, for tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if isLoading {
            loadingTabIDs.insert(tabID)
        } else {
            loadingTabIDs.remove(tabID)
        }
    }

    func moveSelectedTabHorizontally(by offset: Int, keepsPreviewVisible: Bool = false) {
        let candidates = visibleTabs
        guard let selectedTabID, let current = candidates.firstIndex(where: { $0.id == selectedTabID }), candidates.count > 1 else { return }
        let next = (current + offset + candidates.count) % candidates.count
        select(candidates[next].id)
        showTabPreview(keepsVisible: keepsPreviewVisible)
    }

    func selectPreviouslySelectedTab(keepsPreviewVisible: Bool = false) {
        guard let previouslySelectedTabID,
              previouslySelectedTabID != selectedTabID,
              visibleTabs.contains(where: { $0.id == previouslySelectedTabID })
        else {
            moveSelectedTabHorizontally(by: 1, keepsPreviewVisible: keepsPreviewVisible)
            return
        }

        select(previouslySelectedTabID)
        showTabPreview(keepsVisible: keepsPreviewVisible)
    }

    func dismissTabPreview() {
        tabPreviewTask?.cancel()
        tabPreviewID = nil
    }

    func loadSelectedTabIfNeeded(force: Bool = false) {
        guard let tab = selectedTab, let profile = profiles.first(where: { $0.id == tab.profileID }) else { return }
        guard !tab.isNativeNewTab else { return }
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        let needsInitialLoad = webView.url == nil && lastRequestedAddresses[tab.id] != tab.address
        guard force || needsInitialLoad || tab.isSuspended else { return }
        lastRequestedAddresses[tab.id] = tab.address
        webView.load(URLRequest(url: tab.address))
    }

    private func loadedWebView(for tab: BrowserTab?) -> WKWebView? {
        guard let tab, let profile = profiles.first(where: { $0.id == tab.profileID }), WebViewPool.shared.contains(tab.id) else { return nil }
        return WebViewPool.shared.webView(for: tab, profile: profile)
    }

    private static func pngData(from image: NSImage?) -> Data? {
        guard let image,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func requestPictureInPicture(for tabID: UUID) {
        pictureInPictureRequestTabID = tabID
        Task { [weak self] in
            let didAccept = await WebViewPool.shared.enterPictureInPicture(for: tabID)
            if didAccept {
                // ponytail: WebKit can accept the request and then refuse silently, so the wait
                // is bounded instead of holding the web view in the window forever. WebKit's
                // delegate call clears the request sooner when the window does open.
                try? await Task.sleep(for: .seconds(2))
            }
            guard let self, self.pictureInPictureRequestTabID == tabID, self.pictureInPictureTabID != tabID else { return }
            // A window that took longer than the wait to open is adopted, never dropped: dropping
            // it hides the tab that owns the video and leaves the floating window empty.
            if WebViewPool.shared.isPictureInPictureActive(tabID) {
                self.pictureInPictureDidChange(isActive: true, tabID: tabID)
                return
            }
            self.pictureInPictureRequestTabID = nil
        }
    }

    private func releasePictureInPicture(for tabID: UUID) {
        guard pictureInPictureHoldTabID == tabID else { return }
        pictureInPictureTabID = nil
        pictureInPictureRequestTabID = nil
    }

    /// How much browsing history stays in memory. The database keeps the rest.
    static let retainedHistoryCount = 1000

    static func idleTabs(in tabs: [BrowserTab], cutoff: Date, selectedTabID: UUID?) -> [BrowserTab] {
        tabs.filter { tab in
            tab.id != selectedTabID && !tab.isPinned && !tab.isSuspended && tab.lastActivatedAt < cutoff
        }
    }

    private func discardIdleTabs() {
        let cutoff = Date.now.addingTimeInterval(-settings.tabSleepInterval)
        let candidates = Self.idleTabs(in: tabs, cutoff: cutoff, selectedTabID: selectedTabID)
            .filter { WebViewPool.shared.contains($0.id) }
        // A site allowed to notify is one the user wants to hear from: asleep, a chat or a
        // calendar tab has no page left to post the message.
        let notifyingOrigins = Set(SitePermissions.decisions(for: .notifications).filter(\.value).keys)
        for tab in candidates {
            if let origin = SitePermissions.describe(tab.address), notifyingOrigins.contains(origin) { continue }
            // An open Web Inspector session dies with the web process it inspects.
            if let webView = loadedWebView(for: tab), WebInspector.isConnected(for: webView) { continue }
            WebViewPool.shared.holdsPlayback(tab.id) { [weak self] holdsPlayback in
                Task { @MainActor in
                    // A tab playing media or holding a Picture in Picture window keeps its process.
                    guard !holdsPlayback else { return }
                    self?.suspend(tab.id)
                }
            }
        }
    }

    private func suspend(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID && !$0.isSuspended }) else { return }
        releasePictureInPicture(for: tabID)
        audibleTabIDs.remove(tabID)
        update(tabID) { $0.isSuspended = true }
        loadingTabIDs.remove(tabID)
        initialContentReadyTabIDs.remove(tabID)
        cancelInitialContentRevealDeadline(for: tabID)
        lastRequestedAddresses.removeValue(forKey: tabID)
        WebViewPool.shared.takeSnapshot(of: tabID, width: 720) { [weak self] image in
            Task { @MainActor in
                guard self?.tabs.first(where: { $0.id == tabID })?.isSuspended == true else { return }
                self?.update(tabID) { $0.preview = image }
                WebViewPool.shared.discard(tabID)
            }
        }
    }

    private func showTabPreview(keepsVisible: Bool = false) {
        tabPreviewID = selectedTabID
        tabPreviewTask?.cancel()
        guard !keepsVisible else { return }
        tabPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self?.tabPreviewID = nil
        }
    }

    private func update(_ tabID: UUID, mutation: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        mutation(&tabs[index])
        persistWorkspace()
    }

    private func bookmarkSymbol(for address: URL) -> String {
        switch address.host {
        case "www.google.com": "magnifyingglass"
        case "developer.apple.com": "apple.logo"
        case "github.com": "chevron.left.forwardslash.chevron.right"
        default: "globe"
        }
    }

    private func persistBookmarks() {
        persistence.saveBookmarks(bookmarkFolders)
    }

    private func installChromeExtension(from directory: URL) async {
        isExtensionImporting = true
        defer { isExtensionImporting = false }
        do {
            _ = try await extensionRuntime.install(from: directory)
            extensions = extensionRuntime.extensions
        } catch {
            extensionImportError = error.localizedDescription
        }
    }

    /// Every title, address and selection change lands here, and the write rewrites the whole
    /// tab table on the main thread. Coalescing the burst keeps navigation from stuttering.
    private func persistWorkspace() {
        persistWorkspaceTask?.cancel()
        persistWorkspaceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistence.saveWorkspace(
                tabs: self.persistableTabs,
                profiles: self.profiles,
                activeProfileID: self.activeProfileID,
                selectedTabID: self.selectedTabID
            )
        }
    }

    /// A tile's tab belongs to its tile, not to the tab list, so it is left out of the saved
    /// workspace. `loadWorkspace` already falls back when the saved selection is missing.
    private var persistableTabs: [BrowserTab] {
        let ownedTabIDs = Set(quickAccessTabIDs.values)
        return tabs.filter { !ownedTabIDs.contains($0.id) }
    }

    private func persistProfiles() {
        persistence.saveProfiles(profiles)
    }


    private func sanitizedFileName(_ proposedName: String) -> String {
        let fileName = URL(fileURLWithPath: proposedName).lastPathComponent
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Download" : trimmedName
    }

    private func availableDestination(for fileName: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let fileURL = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return fileURL }

        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        for index in 2...10_000 {
            let candidateName = fileExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    }
}

// MARK: - Smart address bar

extension BrowserStore {
    /// Ranks what the user is typing against open tabs, saved pages and browsing history.
    /// Static and `now`-injected so the ordering is testable without a live store, mirroring
    /// `idleTabs(in:cutoff:selectedTabID:)`.
    /// ponytail: a linear scan over the 1000 retained visits, with no index and no cache. That
    /// is microseconds per keystroke and costs nothing when the address bar is closed. Upgrade
    /// path, only if history ever stops being capped: a prefix index kept in BrowserPersistence.
    static func rankedAddressSuggestions(
        for input: String,
        tabs: [BrowserTab],
        bookmarks: [BrowserBookmark],
        history: [BrowsingHistoryEntry],
        now: Date = .now,
        limit: Int = 6
    ) -> [AddressSuggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] }

        // History holds one row per visit, so match first and aggregate only the survivors:
        // a full [URL: visits] map would cost the whole retained history on every keystroke.
        var visits: [URL: (count: Int, lastVisitedAt: Date)] = [:]
        var candidates: [AddressSuggestion] = []
        for entry in history where matchesAddressQuery(query, title: entry.title, address: entry.address) {
            if let visit = visits[entry.address] {
                visits[entry.address] = (visit.count + 1, max(visit.lastVisitedAt, entry.visitedAt))
            } else {
                visits[entry.address] = (1, entry.visitedAt)
                candidates.append(AddressSuggestion(title: entry.title, address: entry.address, source: .history))
            }
        }
        candidates += tabs
            .filter { matchesAddressQuery(query, title: $0.title, address: $0.address) }
            .map { AddressSuggestion(title: $0.title, address: $0.address, source: .tab) }
        candidates += bookmarks
            .filter { matchesAddressQuery(query, title: $0.title, address: $0.address) }
            .map { AddressSuggestion(title: $0.title, address: $0.address, source: .bookmark) }

        let ranked = candidates.sorted { lhs, rhs in
            addressSuggestionScore(lhs, query: query, visits: visits[lhs.address], now: now)
                > addressSuggestionScore(rhs, query: query, visits: visits[rhs.address], now: now)
        }
        // The source bonus is part of the score, so the first copy of a URL to survive is the
        // one from the strongest source. `sorted` is not stable; the score is.
        var seen = Set<URL>()
        return ranked.filter { seen.insert($0.address).inserted }.prefix(limit).map { $0 }
    }

    /// The most likely continuation of what is being typed, as the full completed text. Read
    /// off the already ranked list rather than scanning every candidate a second time.
    static func inlineCompletion(for input: String, in suggestions: [SmartAddressSuggestion]) -> String? {
        let typed = input.lowercased()
        // A scheme or a space means the user is pasting a URL or writing a search phrase;
        // neither is a host they expect the address bar to finish for them.
        guard typed.count >= 2, !typed.contains("://"), !typed.contains(" ") else { return nil }

        for case let .saved(suggestion) in suggestions {
            let host = strippedAddressHost(suggestion.address)
            guard !host.isEmpty else { continue }
            for key in [host, addressCompletionKey(suggestion.address)]
            where key.count > typed.count && key.hasPrefix(typed) {
                return key
            }
        }
        return nil
    }

    /// Arrow-key movement through a suggestion list. Stepping past either end clears the
    /// highlight so the field falls back to whatever the user actually typed.
    static func highlightedSuggestionIndex(from current: Int?, step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step > 0 ? 0 : count - 1 }
        let next = current + step
        return (0..<count).contains(next) ? next : nil
    }

    private static func matchesAddressQuery(_ query: String, title: String, address: URL) -> Bool {
        // jungle://new-tab lives in every fresh tab; completing to it would be nonsense.
        guard BrowserAddress.isWebURL(address) else { return false }
        return title.lowercased().contains(query) || address.absoluteString.lowercased().contains(query)
    }

    private static func addressSuggestionScore(
        _ suggestion: AddressSuggestion,
        query: String,
        visits: (count: Int, lastVisitedAt: Date)?,
        now: Date
    ) -> Int {
        let host = strippedAddressHost(suggestion.address)
        let title = suggestion.title.lowercased()
        // A query that starts a host is a far stronger signal than the same letters buried
        // inside a path or a query string.
        var score =
            if host.hasPrefix(query) { 600 }
            else if title.hasPrefix(query) { 400 }
            else if host.contains(query) { 200 }
            else { 0 }
        if let visits {
            // Frecency: repeat visits keep counting, but a page opened today outranks a page
            // opened twenty times last year.
            score += min(visits.count, 20) * 10
            let days = now.timeIntervalSince(visits.lastVisitedAt) / 86_400
            let recency =
                if days < 1 { 120 }
                else if days < 7 { 70 }
                else if days < 30 { 30 }
                else { 0 }
            score += recency
        }
        let sourceBonus =
            switch suggestion.source {
            case .tab: 30
            case .bookmark: 20
            case .history: 0
            }
        return score + sourceBonus
    }

    private static func strippedAddressHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the address bar shows once the scheme and `www.` are dropped, which is also what
    /// a user types from memory.
    private static func addressCompletionKey(_ url: URL) -> String {
        var key = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        return key
    }
}
