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
    @Published private(set) var copiedTabAddress: URL?
    @Published private(set) var bookmarkFolders: [BookmarkFolder]
    @Published private(set) var history: [BrowsingHistoryEntry]
    @Published private(set) var downloads: [BrowserDownload]

    let settings: BrowserSettings
    private let persistence: BrowserPersistence
    private var housekeepingTask: Task<Void, Never>?
    private var tabPreviewTask: Task<Void, Never>?
    private var copiedAddressFeedbackTask: Task<Void, Never>?
    private var pictureInPictureActivationTask: Task<Void, Never>?
    private var pictureInPictureMonitoringTask: Task<Void, Never>?
    private var pictureInPictureTabID: UUID?
    private var settingsObserver: AnyCancellable?
    private var previouslySelectedTabID: UUID?
    private var lastRequestedAddresses: [UUID: URL] = [:]

    init(settings: BrowserSettings? = nil, persistence: BrowserPersistence? = nil) {
        let resolvedPersistence = persistence ?? BrowserPersistence.shared
        self.persistence = resolvedPersistence
        let browserSettings = settings ?? BrowserSettings(persistence: resolvedPersistence)
        self.settings = browserSettings
        let browserProfiles = resolvedPersistence.loadProfiles()
        let firstTab = BrowserTab(profileID: browserProfiles[0].id, address: browserSettings.searchEngine.homeURL)
        let workspace = resolvedPersistence.loadWorkspace(profiles: browserProfiles)
        profiles = browserProfiles
        tabs = workspace?.tabs ?? [firstTab]
        activeProfileID = browserProfiles[workspace?.activeProfileSlot ?? 0].id
        selectedTabID = workspace?.selectedTabID ?? firstTab.id
        bookmarkFolders = resolvedPersistence.loadBookmarks(for: browserProfiles)
        history = resolvedPersistence.loadHistory()
        downloads = resolvedPersistence.loadDownloads()
        settingsObserver = browserSettings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        housekeepingTask?.cancel()
        tabPreviewTask?.cancel()
        copiedAddressFeedbackTask?.cancel()
        pictureInPictureActivationTask?.cancel()
        pictureInPictureMonitoringTask?.cancel()
    }

    var activeProfile: BrowserProfile { profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0] }
    var selectedTab: BrowserTab? { tabs.first(where: { $0.id == selectedTabID }) }
    var visibleTabs: [BrowserTab] { tabs.filter { $0.profileID == activeProfileID } }
    var visibleHistory: [BrowsingHistoryEntry] { history.filter { $0.profileID == activeProfileID } }
    var visibleDownloads: [BrowserDownload] { downloads.filter { $0.profileID == activeProfileID } }
    var visibleBookmarkFolders: [BookmarkFolder] { bookmarkFolders.filter { $0.profileID == activeProfileID } }
    var isSelectedTabLoading: Bool { selectedTabID.map { loadingTabIDs.contains($0) } ?? false }
    var selectedTabUsesInsecureHTTP: Bool { selectedTab.map { BrowserAddress.usesInsecureHTTP($0.address) } ?? false }

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
        let tab = BrowserTab(profileID: activeProfileID, address: settings.searchEngine.homeURL)
        tabs.append(tab)
        select(tab.id)
    }

    func select(_ tabID: UUID, entersPictureInPictureWhenLeaving: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let previousTabID = selectedTabID
        // Leaving a tab that is playing video sends it to Picture in Picture, the way
        // Safari does. The floating window keeps its own control to return it inline.
        if entersPictureInPictureWhenLeaving, let previousTabID, previousTabID != tabID {
            requestPictureInPicture(for: previousTabID)
        }
        activeProfileID = tabs[index].profileID
        selectedTabID = tabID
        if previousTabID != tabID {
            previouslySelectedTabID = previousTabID
        }
        tabs[index].lastActivatedAt = .now
        tabs[index].isSuspended = false
        persistWorkspace()
    }

    func close(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let profileID = tabs[index].profileID
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: index)
        loadingTabIDs.remove(tabID)
        lastRequestedAddresses.removeValue(forKey: tabID)
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
        close(selectedTabID)
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
        bookmarkFolders.removeAll { $0.profileID == profileID }
        profiles.remove(at: index)
        if activeProfileID == profileID {
            activeProfileID = profiles[0].id
        }
        if !tabs.contains(where: { $0.profileID == activeProfileID }) {
            let tab = BrowserTab(profileID: activeProfileID, address: settings.searchEngine.homeURL)
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

    func reloadSelectedTab() { loadedWebView(for: selectedTab)?.reload() }
    func reloadSelectedTabIgnoringCache() { loadedWebView(for: selectedTab)?.reloadFromOrigin() }

    func togglePictureInPicture() {
        guard let tabID = pictureInPictureTabID ?? selectedTabID else { return }
        Task { [weak self] in
            if await WebViewPool.shared.isPictureInPictureActive(for: tabID) {
                guard await WebViewPool.shared.exitPictureInPicture(for: tabID) else { return }
                self?.restoreTabFromPictureInPicture(tabID)
                return
            }

            guard await WebViewPool.shared.enterPictureInPicture(for: tabID) else { return }
            self?.beginPictureInPictureActivationTracking(for: tabID)
        }
    }

    func restoreTabFromPictureInPicture(_ tabID: UUID) {
        stopPictureInPictureTracking(for: tabID)
        guard selectedTabID != tabID, tabs.contains(where: { $0.id == tabID }) else { return }
        // Returning one PiP window inline must not put media from the current tab in PiP.
        select(tabID, entersPictureInPictureWhenLeaving: false)
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

    func openBookmark(_ bookmark: BrowserBookmark) {
        let tab = BrowserTab(
            profileID: activeProfileID,
            address: bookmark.address,
            title: bookmark.title
        )
        tabs.append(tab)
        select(tab.id)
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
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] }

        let tabCandidates = visibleTabs.map { AddressSuggestion(title: $0.title, address: $0.address, source: .tab) }
        let bookmarkCandidates = bookmarkFolders.flatMap(\.bookmarks).map {
            AddressSuggestion(title: $0.title, address: $0.address, source: .bookmark)
        }
        let matching = (tabCandidates + bookmarkCandidates).filter { suggestion in
            suggestion.title.localizedCaseInsensitiveContains(query)
                || suggestion.address.host?.localizedCaseInsensitiveContains(query) == true
                || suggestion.address.absoluteString.localizedCaseInsensitiveContains(query)
        }
        let ranked = matching.sorted { lhs, rhs in
            suggestionScore(lhs, query: query) > suggestionScore(rhs, query: query)
        }
        var seen = Set<URL>()
        return ranked.filter { seen.insert($0.address).inserted }.prefix(5).map { $0 }
    }

    func saveCurrentPage(to folderID: UUID) {
        guard let tab = selectedTab,
              let index = bookmarkFolders.firstIndex(where: { $0.id == folderID && $0.profileID == activeProfileID }) else { return }
        guard !bookmarkFolders[index].bookmarks.contains(where: { $0.address == tab.address }) else { return }
        let bookmark = BrowserBookmark(title: tab.title, address: tab.address, symbol: bookmarkSymbol(for: tab.address))
        bookmarkFolders[index].bookmarks.append(bookmark)
        persistBookmarks()
    }

    func createBookmarkFolder(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        bookmarkFolders.append(BookmarkFolder(profileID: activeProfileID, name: trimmedName))
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
    func copySelectedTabAddress() {
        guard let address = selectedTab?.address else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(address.absoluteString, forType: .string) else { return }
        copiedTabAddress = address
        copiedAddressFeedbackTask?.cancel()
        copiedAddressFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedTabAddress = nil
        }
    }

    static func commandClickDestination(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        shouldPerformDownload: Bool,
        requestURL: URL?
    ) -> URL? {
        guard navigationType == .linkActivated,
              modifierFlags.contains(.command),
              !shouldPerformDownload,
              let requestURL,
              BrowserAddress.isWebURL(requestURL)
        else { return nil }
        return requestURL
    }
    func togglePinned(_ tabID: UUID) { update(tabID) { $0.isPinned.toggle() } }

    func didCommitNavigation(for tabID: UUID, url: URL?) { if let url { update(tabID) { $0.address = url } } }

    func didStartNavigation(for tabID: UUID) {
        setNavigationLoading(true, for: tabID)
    }

    func didFinishNavigation(for tabID: UUID, title: String?, url: URL?) {
        setNavigationLoading(false, for: tabID)
        update(tabID) { tab in
            if let url { tab.address = url }
            let candidate = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            tab.title = candidate.isEmpty ? (tab.address.host ?? tab.address.absoluteString) : candidate
        }
        guard let tab = tabs.first(where: { $0.id == tabID }), BrowserAddress.isWebURL(tab.address) else { return }
        let entry = BrowsingHistoryEntry(profileID: tab.profileID, title: tab.title, address: tab.address)
        history.insert(entry, at: 0)
        persistence.saveHistoryEntry(entry)
    }

    func didFailNavigation(for tabID: UUID) {
        setNavigationLoading(false, for: tabID)
    }

    func didTerminateWebContent(for tabID: UUID) {
        setNavigationLoading(false, for: tabID)
        lastRequestedAddresses.removeValue(forKey: tabID)
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

    private func requestPictureInPicture(for tabID: UUID) {
        pictureInPictureActivationTask?.cancel()
        pictureInPictureActivationTask = Task { [weak self] in
            guard await WebViewPool.shared.enterPictureInPicture(for: tabID), !Task.isCancelled else { return }
            self?.beginPictureInPictureActivationTracking(for: tabID)
        }
    }

    private func beginPictureInPictureActivationTracking(for tabID: UUID) {
        pictureInPictureActivationTask?.cancel()
        pictureInPictureTabID = tabID
        pictureInPictureActivationTask = Task { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.tabs.contains(where: { $0.id == tabID }) else { return }
                if await WebViewPool.shared.isPictureInPictureActive(for: tabID) {
                    self.startPictureInPictureMonitoring(for: tabID)
                    return
                }
            }
            self?.stopPictureInPictureTracking(for: tabID)
        }
    }

    private func startPictureInPictureMonitoring(for tabID: UUID) {
        pictureInPictureTabID = tabID
        pictureInPictureMonitoringTask?.cancel()
        pictureInPictureMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                guard self.tabs.contains(where: { $0.id == tabID }) else {
                    self.stopPictureInPictureTracking(for: tabID)
                    return
                }
                guard await WebViewPool.shared.isPictureInPictureActive(for: tabID) else {
                    self.restoreTabFromPictureInPicture(tabID)
                    return
                }
            }
        }
    }

    private func stopPictureInPictureTracking(for tabID: UUID) {
        guard pictureInPictureTabID == tabID else { return }
        pictureInPictureTabID = nil
        pictureInPictureActivationTask?.cancel()
        pictureInPictureActivationTask = nil
        pictureInPictureMonitoringTask?.cancel()
        pictureInPictureMonitoringTask = nil
    }

    static func idleTabs(in tabs: [BrowserTab], cutoff: Date, selectedTabID: UUID?) -> [BrowserTab] {
        tabs.filter { tab in
            tab.id != selectedTabID && !tab.isPinned && !tab.isSuspended && tab.lastActivatedAt < cutoff
        }
    }

    private func discardIdleTabs() {
        let cutoff = Date.now.addingTimeInterval(-settings.tabSleepInterval)
        let candidates = Self.idleTabs(in: tabs, cutoff: cutoff, selectedTabID: selectedTabID)
            .filter { WebViewPool.shared.contains($0.id) }
        for tab in candidates {
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
        update(tabID) { $0.isSuspended = true }
        loadingTabIDs.remove(tabID)
        lastRequestedAddresses.removeValue(forKey: tabID)
        WebViewPool.shared.takeSnapshot(of: tabID) { [weak self] image in
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

    private func persistWorkspace() {
        persistence.saveWorkspace(tabs: tabs, profiles: profiles, activeProfileID: activeProfileID, selectedTabID: selectedTabID)
    }

    private func persistProfiles() {
        persistence.saveProfiles(profiles)
    }

    private func suggestionScore(_ suggestion: AddressSuggestion, query: String) -> Int {
        let title = suggestion.title.lowercased()
        let host = suggestion.address.host?.lowercased() ?? ""
        if title.hasPrefix(query) || host.hasPrefix(query) { return 3 }
        if suggestion.source == .tab { return 2 }
        return 1
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
