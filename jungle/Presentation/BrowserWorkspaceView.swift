import AppKit
import SwiftUI

struct BrowserWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var store = BrowserStore()
    @State private var addressInput = ""

    private var usesDarkContent: Bool {
        store.settings.appearance.usesDarkContent(systemIsDark: colorScheme == .dark)
    }

    var body: some View {
        workspaceWithKeyboardHandling
    }

    private var workspaceLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    BrowserSidebar(store: store, addressInput: $addressInput)
                        .frame(width: 268)
                        .background(SidebarSurface())
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                browserContent
                    .background(Color(nsColor: WebViewPool.contentBackground(isDark: usesDarkContent)))
            }

            if let previewID = store.tabPreviewID,
               let tab = store.visibleTabs.first(where: { $0.id == previewID }) {
                TabNavigationPreview(tab: tab, tabs: store.visibleTabs)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private var configuredWorkspaceLayout: some View {
        workspaceLayout
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(store.settings.appearance.colorScheme)
        .animation(.easeInOut(duration: 0.18), value: store.isSidebarVisible)
        .animation(.easeInOut(duration: 0.12), value: store.tabPreviewID)
        .task {
            addressInput = store.selectedTab?.address.absoluteString ?? ""
            store.beginMemoryHousekeeping()
            ContentBlocking.shared.start()
            ApplicationIconController.update(for: store.settings.appearance)
            publishTrafficLightsVisibility()
        }
        .onChange(of: store.settings.appearance) { _, appearance in
            ApplicationIconController.update(for: appearance)
        }
        .onChange(of: colorScheme) { _, _ in
            ApplicationIconController.update(for: store.settings.appearance)
        }
        .onChange(of: store.isSidebarVisible) { _, _ in publishTrafficLightsVisibility() }
        .onChange(of: store.selectedTabID) { _, _ in
            addressInput = store.selectedTab?.address.absoluteString ?? ""
        }
    }

    private var workspaceWithNotifications: some View {
        workspaceWithPrimaryCommands
        .onReceive(NotificationCenter.default.publisher(for: .jungleBeginTabCycle)) { _ in
            store.selectPreviouslySelectedTab(keepsPreviewVisible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleAdvanceTabCycle)) { _ in
            store.moveSelectedTabHorizontally(by: 1, keepsPreviewVisible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleSelectPreviousTab)) { _ in
            store.selectPreviouslySelectedTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleMoveTabWhileCycling)) { notification in
            guard let offset = notification.userInfo?["offset"] as? Int else { return }
            store.moveSelectedTabHorizontally(by: offset, keepsPreviewVisible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleDismissTabCycle)) { _ in store.dismissTabPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleToggleSidebar)) { _ in store.toggleSidebar() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleSwitchProfile)) { notification in
            guard let number = notification.userInfo?["number"] as? Int else { return }
            store.switchProfile(number: number)
        }
    }

    private var workspaceWithPrimaryCommands: some View {
        configuredWorkspaceLayout
        .onReceive(NotificationCenter.default.publisher(for: .jungleNewTab)) { _ in store.createTab() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleCloseTab)) { _ in store.closeSelectedTab() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleCommandPalette)) { _ in
            store.isCommandPalettePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleOpenSettings)) { _ in
            store.isSettingsPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleShowHistory)) { _ in
            store.isHistoryPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleShowDownloads)) { _ in
            store.isDownloadsPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleGoBack)) { _ in store.goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleGoForward)) { _ in store.goForward() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleCopyActiveTabURL)) { _ in store.copySelectedTabAddress() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleReload)) { _ in store.reloadSelectedTab() }
    }

    private var workspaceWithMediaAndDeveloperCommands: some View {
        workspaceWithNotifications
        .onReceive(NotificationCenter.default.publisher(for: .jungleReloadIgnoringCache)) { _ in store.reloadSelectedTabIgnoringCache() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleTogglePictureInPicture)) { _ in store.togglePictureInPicture() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleToggleWebInspector)) { _ in store.toggleWebInspector() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleShowJavaScriptConsole)) { _ in store.showJavaScriptConsole() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleDeveloperMetricsDidUpdate)) { notification in
            guard let tabID = notification.userInfo?["tabID"] as? UUID,
                  let metrics = notification.userInfo?["metrics"] as? DeveloperMetrics
            else { return }
            store.recordDeveloperMetrics(metrics, for: tabID)
        }
    }

    private var workspaceWithKeyboardHandling: some View {
        workspaceWithMediaAndDeveloperCommands
        .onKeyPress(.return, action: dismissTabPreviewIfPresented)
        .onKeyPress(.escape, action: dismissTabPreviewIfPresented)
        .onOpenURL { store.openExternalURL($0) }
        .sheet(isPresented: $store.isCommandPalettePresented) { CommandPalette(store: store) }
        .sheet(isPresented: $store.isSettingsPresented) { BrowserSettingsView(settings: store.settings, store: store) }
        .sheet(isPresented: $store.isHistoryPresented) { BrowserHistoryView(store: store) }
        .sheet(isPresented: $store.isDownloadsPresented) { BrowserDownloadsView(store: store) }
    }

    @ViewBuilder
    private var browserContent: some View {
        if let tab = store.selectedTab {
            VStack(spacing: 0) {
                if store.selectedTabIsLocalDevelopment {
                    LocalDevelopmentToolbar(store: store, tab: tab)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack(alignment: .bottomTrailing) {
                    // One web container for the whole session: switching tabs must never pull a
                    // web view out of the window, or WebKit closes its Picture in Picture window.
                    BrowserWebView(store: store)

                    if !tab.isSuspended && !store.selectedTabInitialContentIsReady {
                        Color(nsColor: WebViewPool.contentBackground(isDark: usesDarkContent))
                            .allowsHitTesting(false)
                    }

                    if tab.isSuspended {
                        SuspendedTabView(tab: tab, resume: { store.select(tab.id) })
                            .background(Color(nsColor: WebViewPool.contentBackground(isDark: usesDarkContent)))
                    }

                    VStack(alignment: .trailing, spacing: 8) {
                        if let copiedAddress = store.copiedTabAddress {
                            CopiedAddressFeedback(address: copiedAddress)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if store.isSelectedTabLoading {
                            NavigationFeedback(title: tab.address.host ?? "Loading page")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(18)
                }
                .animation(.easeOut(duration: 0.16), value: store.isSelectedTabLoading)
                .animation(.easeOut(duration: 0.16), value: store.copiedTabAddress)
            }
            .animation(.spring(duration: 0.28, bounce: 0.16), value: store.selectedTabIsLocalDevelopment)
            .opacity(store.isClosingTab(tab.id) ? 0.08 : 1)
            .scaleEffect(store.isClosingTab(tab.id) ? 0.985 : 1)
            .blur(radius: store.isClosingTab(tab.id) ? 1.5 : 0)
            .animation(.easeIn(duration: 0.16), value: store.isClosingTab(tab.id))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func publishTrafficLightsVisibility() {
        NotificationCenter.default.post(
            name: .jungleTrafficLightsVisibility,
            object: nil,
            userInfo: ["isVisible": store.isSidebarVisible]
        )
    }

    private func dismissTabPreviewIfPresented() -> KeyPress.Result {
        guard store.tabPreviewID != nil else { return .ignored }
        store.dismissTabPreview()
        return .handled
    }

}

private struct SidebarSurface: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(
                    colors: [Color.green.opacity(0.10), Color.indigo.opacity(0.04), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

private struct NavigationFeedback: View {
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).tint(.green)
            Text("Loading \(title)")
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14)))
        .shadow(radius: 10, y: 4)
    }
}

private struct CopiedAddressFeedback: View {
    let address: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("URL copied")
                .font(.system(size: 12, weight: .medium, design: .rounded))
            Text(address.host ?? address.absoluteString)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14)))
        .shadow(radius: 10, y: 4)
    }
}

private struct LocalDevelopmentToolbar: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("Local", systemImage: "hammer.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.trailing, 2)

                Text(tab.address.host ?? "Local development")
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let metrics = store.selectedDeveloperMetrics {
                    metric("JS", value: heapDescription(metrics.javaScriptHeapBytes), help: "JavaScript heap for this page when WebKit exposes it")
                    metric("Load", value: durationDescription(metrics.loadDurationMilliseconds), help: "Navigation timing reported by the page")
                    metric("Req", value: "\(metrics.requestCount)", help: "Main navigation plus resource timing entries observed while loading")
                    metric("Data", value: ByteCountFormatter.string(fromByteCount: metrics.transferredBytes, countStyle: .file), help: "Transferred resource bytes reported by the page")
                    if metrics.repeatedRequestCount > 0 {
                        Label("\(metrics.repeatedRequestCount) repeated", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .help("Resources requested more than once during this load")
                    }
                } else {
                    ProgressView().controlSize(.mini).tint(.green)
                    Text("Reading page metrics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 18)

                toolbarButton("arrow.clockwise", label: "Hard reload", help: "Reload without using cached resources") {
                    store.reloadSelectedTabIgnoringCache()
                }
                toolbarButton("wrench.and.screwdriver", label: "DevTools", help: "Show Web Inspector") {
                    store.toggleWebInspector()
                }
                toolbarButton("terminal", label: "Console", help: "Show the JavaScript Console") {
                    store.showJavaScriptConsole()
                }
                toolbarButton(
                    store.copiedScreenshotTabID == tab.id ? "checkmark" : "camera",
                    label: store.copiedScreenshotTabID == tab.id ? "Copied" : "Screenshot",
                    help: "Copy a PNG screenshot of this tab to the clipboard"
                ) {
                    store.copySelectedTabScreenshot()
                }
                toolbarButton("chart.bar", label: "Refresh", help: "Refresh the page metrics") {
                    store.refreshSelectedDeveloperMetrics()
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 42)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.green.opacity(0.28)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local development toolbar")
    }

    private func metric(_ title: String, value: String, help: String) -> some View {
        Text("\(title) \(value)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help(help)
    }

    private func toolbarButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .buttonStyle(.borderless)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(label)
    }

    private func heapDescription(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func durationDescription(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return "\(milliseconds) ms"
    }
}

private struct TabNavigationPreview: View {
    let tab: BrowserTab
    let tabs: [BrowserTab]

    private let cardWidth: CGFloat = 172
    private let cardSpacing: CGFloat = 8

    private var columnCount: Int { min(max(tabs.count, 1), 4) }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: cardSpacing), count: columnCount)
    }

    private var contentWidth: CGFloat {
        max(CGFloat(columnCount) * cardWidth + CGFloat(columnCount - 1) * cardSpacing, 352)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "rectangle.3.group.fill").foregroundStyle(.green)
                Text("Open tabs").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text("Release ⌃ to keep")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("⌃⇥ or ⌃←/→ to cycle").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: gridColumns,
                alignment: .leading,
                spacing: cardSpacing
            ) {
                ForEach(tabs) { item in
                    TabNavigationCard(tab: item, isSelected: item.id == tab.id)
                }
            }
            Text(tab.address.host ?? tab.address.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.22)))
        .shadow(radius: 22, y: 10)
        .padding(28)
    }
}

private struct TabNavigationCard: View {
    let tab: BrowserTab
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TabFavicon(address: tab.address, isSuspended: tab.isSuspended, isPinned: tab.isPinned)
                .frame(width: 20, height: 20)
            Text(tab.title)
                .lineLimit(1)
                .font(.caption.weight(isSelected ? .semibold : .regular))
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(10)
        .background(isSelected ? Color.green.opacity(0.22) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(isSelected ? Color.green.opacity(0.42) : .white.opacity(0.10)))
        .scaleEffect(isSelected ? 1 : 0.96)
    }
}

private struct BrowserSidebar: View {
    @ObservedObject var store: BrowserStore
    @Binding var addressInput: String
    @State private var isNewFolderPresented = false
    @State private var newFolderName = ""
    @State private var draggedItem: BrowserDragPayload?
    @State private var activeDropTarget: SidebarDropTarget?
    @State private var dropTargetFrames: [SidebarDropTarget: CGRect] = [:]
    @State private var dragPosition: CGPoint?
    @State private var completedDropTarget: SidebarDropTarget?
    @State private var completionID: UUID?
    @State private var suppressActivationUntil = Date.distantPast
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            trafficLightProfileRow
            sidebarHeader
            navigationBar
            quickAccess

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.visibleBookmarkFolders.filter { !$0.isQuickAccess }) { folder in
                        bookmarkFolder(folder)
                    }

                    if !store.visibleBookmarkFolders.filter({ !$0.isQuickAccess }).isEmpty {
                        Divider()
                            .overlay(.primary.opacity(0.035))
                            .padding(.horizontal, 8)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                    }

                    let pinnedTabs = store.visibleTabs.filter(\.isPinned)
                    if !pinnedTabs.isEmpty {
                        sidebarLabel("PINNED")
                        ForEach(pinnedTabs) { tab in tabRow(tab) }
                        if draggedTabIsPinned {
                            tabAppendDropTarget(isPinned: true)
                        }
                    }
                    openTabsHeader
                    ForEach(store.visibleTabs.filter { !$0.isPinned }) { tab in tabRow(tab) }
                    if draggedItem?.kind == .tab, !draggedTabIsPinned {
                        tabAppendDropTarget(isPinned: false)
                    }
                    if draggedItem?.kind == .bookmark || completedDropTarget == .removal {
                        bookmarkRemovalDropZone
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.26, bounce: 0.16), value: store.visibleTabs.map(\.id))
                .animation(.easeOut(duration: 0.16), value: store.closingTabIDs)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })

            sidebarFooter
                .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
        }
        .coordinateSpace(name: SidebarDragSpace.name)
        .onPreferenceChange(SidebarDropTargetPreferenceKey.self) { dropTargetFrames = $0 }
        .overlay(alignment: .topLeading) { dragPreviewOverlay }
        .alert("New folder", isPresented: $isNewFolderPresented) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                store.createBookmarkFolder(named: newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Create a place for pages you want close at hand.")
        }
        .onDisappear(perform: clearDragState)
    }

    private var sidebarHeader: some View {
        HStack {
            Button(action: {
                dismissAddressFocus()
                store.toggleSidebar()
            }) { Image(systemName: "sidebar.left") }
                .buttonStyle(ChromeIconButtonStyle())
                .accessibilityLabel("Toggle sidebar")
            Spacer(minLength: 0)
            chromeButton("chevron.left", label: "Back", action: store.goBack)
            chromeButton("chevron.right", label: "Forward", action: store.goForward)
            chromeButton(store.isSelectedTabLoading ? "xmark" : "arrow.clockwise", label: store.isSelectedTabLoading ? "Stop loading" : "Refresh") {
                if store.isSelectedTabLoading { store.stopLoadingSelectedTab() } else { store.reloadSelectedTab() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
    }

    private var trafficLightProfileRow: some View {
        HStack {
            Spacer()
            profilePicker
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
    }

    private var navigationBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: store.selectedTabUsesInsecureHTTP ? "lock.slash.fill" : "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.selectedTabUsesInsecureHTTP ? Color.red : Color.secondary)
                    .accessibilityLabel(store.selectedTabUsesInsecureHTTP ? "Not secure connection" : "Secure connection")
                    .help(store.selectedTabUsesInsecureHTTP ? "This page uses an insecure HTTP connection" : "Secure HTTPS connection")
                TextField("Search or enter address", text: $addressInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .focused($isAddressFocused)
                    .onSubmit {
                        store.navigate(to: addressInput)
                        dismissAddressFocus()
                    }
                if store.isSelectedTabLoading { ProgressView().controlSize(.mini).tint(.green) }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))

            if isAddressFocused, !store.addressSuggestions(for: addressInput).isEmpty {
                addressSuggestions
            }
        }
        .padding(.horizontal, 12)
    }

    private var addressSuggestions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(store.addressSuggestions(for: addressInput)) { suggestion in
                Button {
                    addressInput = suggestion.address.absoluteString
                    isAddressFocused = false
                    store.navigate(to: addressInput)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.source.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title).lineLimit(1).font(.system(size: 12, weight: .medium, design: .rounded))
                            Text(suggestion.address.host ?? suggestion.address.absoluteString)
                                .lineLimit(1)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(suggestion.source.label).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .interactiveHover(cornerRadius: 8)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.16)))
        .shadow(radius: 8, y: 4)
        .padding(.top, 4)
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sidebarLabel("QUICK ACCESS")
                Spacer()
                Menu {
                    if let folder = store.visibleBookmarkFolders.first(where: \.isQuickAccess) {
                        Button("Save current page") { store.saveCurrentPage(to: folder.id) }
                        if !folder.bookmarks.isEmpty { Divider() }
                        ForEach(folder.bookmarks) { bookmark in
                            Button("Remove \(bookmark.title)", role: .destructive) {
                                store.deleteBookmark(bookmark.id, from: folder.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Quick Access options")
                .pointerCursor()
            }
            LazyVGrid(columns: quickAccessGridColumns, spacing: 7) {
                if let folder = quickAccessFolder {
                    ForEach(folder.bookmarks) { bookmark in
                        quickAccessTile(bookmark, folderID: folder.id)
                    }
                    if draggedItem != nil {
                        quickAccessAppendDropTarget(folderID: folder.id)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background {
            if let folder = quickAccessFolder, isQuickAccessTargeted(folder.id) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.green.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.green.opacity(0.55), lineWidth: 1.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, -4)
            }
        }
        .animation(.easeOut(duration: 0.14), value: activeDropTarget)
    }

    private var quickAccessBookmarks: [BrowserBookmark] {
        quickAccessFolder?.bookmarks ?? []
    }

    private var quickAccessFolder: BookmarkFolder? {
        store.visibleBookmarkFolders.first(where: \.isQuickAccess)
    }

    private var quickAccessGridColumns: [GridItem] {
        let count = quickAccessBookmarks.count
        let columnCount: Int
        switch count {
        case 0:
            columnCount = 1
        case 1...3:
            columnCount = count
        default:
            columnCount = 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 7), count: columnCount)
    }

    private func bookmarkFolder(_ folder: BookmarkFolder) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { store.toggleFolder(folder.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                    Text(folder.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isFolderTargeted(folder.id) ? Color.green.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isFolderTargeted(folder.id) ? Color.green.opacity(0.58) : .clear, lineWidth: 1.5))
            .interactiveHover(cornerRadius: 9)
            .sidebarDropTarget(.folder(folder.id))
            .animation(.easeOut(duration: 0.14), value: activeDropTarget)
            .contextMenu {
                Button("Save current page") { store.saveCurrentPage(to: folder.id) }
                Button("Delete folder", role: .destructive) { store.deleteFolder(folder.id) }
            }
            if folder.isExpanded {
                ForEach(folder.bookmarks) { bookmark in
                    folderBookmarkRow(bookmark, folderID: folder.id)
                }
            }
        }
    }

    private var sidebarFooter: some View {
        HStack {
            Button { store.isSettingsPresented = true } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
            Button { isNewFolderPresented = true } label: {
                Image(systemName: "folder.badge.plus").font(.subheadline.weight(.medium))
            }
            .help("Create folder")
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Create bookmark folder")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var profilePicker: some View {
        Menu {
            ForEach(store.profiles) { profile in
                Button(profile.name) { store.switchProfile(to: profile.id) }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: store.activeProfile.symbol)
                    .foregroundStyle(Color(nsColor: store.activeProfile.tint.color))
                    .frame(width: 25, height: 25)
                    .background(Color(nsColor: store.activeProfile.tint.color).opacity(0.12), in: Circle())
                Text(store.activeProfile.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("⌃\(store.profiles.firstIndex(of: store.activeProfile).map { $0 + 1 } ?? 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .padding(.trailing, 12)
        .pointerCursor()
    }

    private func sidebarLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 7)
    }

    private var openTabsHeader: some View {
        HStack {
            sidebarLabel("OPEN TABS")
            Spacer()
            Button(action: store.createTab) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("New tab")
            .accessibilityLabel("New tab")
            .padding(.trailing, 8)
        }
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        SidebarTabRow(
            store: store,
            tab: tab,
            isDropTargeted: isTabTargeted(tab.id),
            isDragging: draggedItem == .tab(tab.id),
            suppressActivation: shouldSuppressActivation,
            beginDrag: beginDrag,
            dragChanged: dragChanged,
            finishDrag: finishDrag
        )
    }

    private var draggedTabIsPinned: Bool {
        guard let draggedItem, draggedItem.kind == .tab else { return false }
        return store.visibleTabs.first(where: { $0.id == draggedItem.id })?.isPinned ?? false
    }

    private func tabAppendDropTarget(isPinned: Bool) -> some View {
        Capsule()
            .fill(activeDropTarget == .tabEnd(isPinned: isPinned) ? Color.green.opacity(0.78) : Color.primary.opacity(0.10))
            .frame(height: activeDropTarget == .tabEnd(isPinned: isPinned) ? 5 : 2)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .sidebarDropTarget(.tabEnd(isPinned: isPinned))
            .accessibilityLabel("Move tab to end of list")
    }

    private func quickAccessTile(_ bookmark: BrowserBookmark, folderID: UUID) -> some View {
        Button { if !shouldSuppressActivation { store.openBookmark(bookmark) } } label: {
            TabFavicon(address: bookmark.address, isSuspended: false, isPinned: false, fallbackSymbol: bookmark.symbol)
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(isBookmarkTargeted(bookmark.id) ? Color.green.opacity(0.7) : .white.opacity(0.10), lineWidth: isBookmarkTargeted(bookmark.id) ? 2 : 1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .interactiveHover(cornerRadius: 11)
        .animation(.spring(duration: 0.18, bounce: 0.12), value: activeDropTarget)
        .help(bookmark.title)
        .accessibilityLabel(bookmark.title)
        .sidebarDropTarget(.bookmark(bookmarkID: bookmark.id, folderID: folderID))
        .sidebarDragGesture(payload: .bookmark(bookmark.id, folderID: folderID), source: .bookmark(bookmarkID: bookmark.id, folderID: folderID), began: beginDrag, changed: dragChanged, ended: finishDrag)
        .scaleEffect(isBookmarkTargeted(bookmark.id) ? 1.035 : (draggedItem == .bookmark(bookmark.id, folderID: folderID) ? 0.96 : 1))
        .opacity(draggedItem == .bookmark(bookmark.id, folderID: folderID) ? 0.45 : 1)
        .contextMenu {
            Button("Remove from Quick Access", role: .destructive) { store.deleteBookmark(bookmark.id, from: folderID) }
        }
    }

    private func folderBookmarkRow(_ bookmark: BrowserBookmark, folderID: UUID) -> some View {
        Button { if !shouldSuppressActivation { store.openBookmark(bookmark) } } label: {
            HStack(spacing: 8) {
                TabFavicon(address: bookmark.address, isSuspended: false, isPinned: false, fallbackSymbol: bookmark.symbol)
                    .frame(width: 14, height: 14)
                Text(bookmark.title)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(isBookmarkTargeted(bookmark.id) ? Color.green.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isBookmarkTargeted(bookmark.id) ? Color.green.opacity(0.62) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .interactiveHover(cornerRadius: 8)
        .animation(.spring(duration: 0.18, bounce: 0.12), value: activeDropTarget)
        .sidebarDropTarget(.bookmark(bookmarkID: bookmark.id, folderID: folderID))
        .sidebarDragGesture(payload: .bookmark(bookmark.id, folderID: folderID), source: .bookmark(bookmarkID: bookmark.id, folderID: folderID), began: beginDrag, changed: dragChanged, ended: finishDrag)
        .scaleEffect(isBookmarkTargeted(bookmark.id) ? 1.015 : (draggedItem == .bookmark(bookmark.id, folderID: folderID) ? 0.98 : 1))
        .opacity(draggedItem == .bookmark(bookmark.id, folderID: folderID) ? 0.45 : 1)
        .contextMenu {
            Button("Remove bookmark", role: .destructive) { store.deleteBookmark(bookmark.id, from: folderID) }
        }
    }

    private func quickAccessAppendDropTarget(folderID: UUID) -> some View {
        Image(systemName: "plus")
            .font(.caption.weight(.bold))
            .foregroundStyle(isQuickAccessTargeted(folderID) ? Color.green : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isQuickAccessTargeted(folderID) ? Color.green.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(isQuickAccessTargeted(folderID) ? Color.green.opacity(0.65) : Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: isQuickAccessTargeted(folderID) ? 1.5 : 1, dash: [4, 3])))
            .sidebarDropTarget(.quickAccess(folderID))
            .accessibilityLabel("Add to Quick Access")
    }

    private var bookmarkRemovalDropZone: some View {
        Label("Drop saved page here to remove", systemImage: "trash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isRemovalTargeted ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isRemovalTargeted ? Color.red.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isRemovalTargeted ? Color.red.opacity(0.62) : Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: isRemovalTargeted ? 1.5 : 1, dash: [4, 3])))
            .padding(.top, 10)
            .sidebarDropTarget(.removal)
            .help("Drag a saved page here to remove it from its folder or Quick Access")
    }

    private func chromeButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            dismissAddressFocus()
            action()
        }) { Image(systemName: symbol) }
            .buttonStyle(ChromeIconButtonStyle())
            .accessibilityLabel(label)
    }

    private func dismissAddressFocus() {
        isAddressFocused = false
    }

    private var shouldSuppressActivation: Bool {
        Date() < suppressActivationUntil
    }

    @ViewBuilder
    private var dragPreviewOverlay: some View {
        if let preview = dragPreview, let dragPosition {
            SidebarDragPreview(preview: preview)
                .position(x: dragPosition.x + 14, y: dragPosition.y + 18)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .allowsHitTesting(false)
        }
    }

    private var dragPreview: SidebarDragPreview.Model? {
        guard let draggedItem else { return nil }
        switch draggedItem.kind {
        case .tab:
            guard let tab = store.visibleTabs.first(where: { $0.id == draggedItem.id }) else { return nil }
            return SidebarDragPreview.Model(
                title: tab.title,
                address: tab.address,
                symbol: tab.isPinned ? "pin.fill" : "globe",
                label: "Tab"
            )
        case .bookmark:
            guard let folderID = draggedItem.folderID,
                  let folder = store.visibleBookmarkFolders.first(where: { $0.id == folderID }),
                  let bookmark = folder.bookmarks.first(where: { $0.id == draggedItem.id })
            else { return nil }
            return SidebarDragPreview.Model(
                title: bookmark.title,
                address: bookmark.address,
                symbol: bookmark.symbol,
                label: "Saved page"
            )
        }
    }

    private func beginDrag(_ payload: BrowserDragPayload) {
        if draggedItem != payload {
            draggedItem = payload
            activeDropTarget = nil
            completedDropTarget = nil
            completionID = nil
        }
    }

    private func dragChanged(source: SidebarDropTarget, location: CGPoint) {
        guard let draggedItem, let sourceFrame = dropTargetFrames[source] else { return }
        let point = CGPoint(x: sourceFrame.minX + location.x, y: sourceFrame.minY + location.y)
        dragPosition = point
        activeDropTarget = dropTarget(at: point, for: draggedItem)
    }

    private func finishDrag(source: SidebarDropTarget, location: CGPoint) {
        defer {
            suppressActivationUntil = Date().addingTimeInterval(0.25)
            clearDragState()
        }
        guard let draggedItem, let sourceFrame = dropTargetFrames[source] else { return }
        let point = CGPoint(x: sourceFrame.minX + location.x, y: sourceFrame.minY + location.y)
        guard let target = dropTarget(at: point, for: draggedItem) else { return }

        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            performDrop(draggedItem, onto: target)
            completedDropTarget = target
        }
        let completionID = UUID()
        self.completionID = completionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard self.completionID == completionID else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                completedDropTarget = nil
            }
        }
    }

    private func dropTarget(at point: CGPoint, for payload: BrowserDragPayload) -> SidebarDropTarget? {
        dropTargetFrames
            .filter { target, frame in frame.contains(point) && accepts(payload, target: target) }
            .sorted { first, second in
                first.value.width * first.value.height < second.value.width * second.value.height
            }
            .first?
            .key
    }

    private func accepts(_ payload: BrowserDragPayload, target: SidebarDropTarget) -> Bool {
        switch (payload.kind, target) {
        case (.tab, .tab), (.tab, .folder), (.tab, .quickAccess):
            return true
        case let (.tab, .tabEnd(isPinned)):
            return store.visibleTabs.first(where: { $0.id == payload.id })?.isPinned == isPinned
        case let (.tab, .bookmark(_, folderID)):
            return quickAccessFolder?.id == folderID
        case (.bookmark, .bookmark), (.bookmark, .folder), (.bookmark, .quickAccess), (.bookmark, .removal):
            return true
        default:
            return false
        }
    }

    private func performDrop(_ payload: BrowserDragPayload, onto target: SidebarDropTarget) {
        switch payload.kind {
        case .tab:
            switch target {
            case let .tab(destinationID) where destinationID != payload.id:
                store.moveTab(payload.id, before: destinationID)
            case .tabEnd:
                store.moveTab(payload.id, before: nil)
            case let .folder(folderID), let .quickAccess(folderID), let .bookmark(_, folderID):
                store.saveTab(payload.id, to: folderID)
            default:
                break
            }
        case .bookmark:
            guard let sourceFolderID = payload.folderID else { return }
            switch target {
            case let .bookmark(destinationID, destinationFolderID) where destinationID != payload.id:
                store.moveBookmark(payload.id, from: sourceFolderID, to: destinationFolderID, before: destinationID)
            case let .folder(destinationFolderID), let .quickAccess(destinationFolderID):
                store.moveBookmark(payload.id, from: sourceFolderID, to: destinationFolderID, before: nil)
            case .removal:
                store.deleteBookmark(payload.id, from: sourceFolderID)
            default:
                break
            }
        }
    }

    private func isTabTargeted(_ id: UUID) -> Bool {
        activeDropTarget == .tab(id) || completedDropTarget == .tab(id)
    }

    private func isBookmarkTargeted(_ id: UUID) -> Bool {
        if case let .bookmark(bookmarkID, _) = activeDropTarget { return bookmarkID == id }
        if case let .bookmark(bookmarkID, _) = completedDropTarget { return bookmarkID == id }
        return false
    }

    private func isFolderTargeted(_ id: UUID) -> Bool {
        activeDropTarget == .folder(id) || completedDropTarget == .folder(id)
    }

    private func isQuickAccessTargeted(_ id: UUID) -> Bool {
        activeDropTarget == .quickAccess(id) || completedDropTarget == .quickAccess(id)
    }

    private var isRemovalTargeted: Bool {
        activeDropTarget == .removal || completedDropTarget == .removal
    }

    private func clearDragState() {
        draggedItem = nil
        activeDropTarget = nil
        dragPosition = nil
    }

}

private struct SidebarDragPreview: View {
    struct Model: Equatable {
        let title: String
        let address: URL
        let symbol: String
        let label: String
    }

    let preview: Model

    var body: some View {
        HStack(spacing: 8) {
            TabFavicon(address: preview.address, isSuspended: false, isPinned: false, fallbackSymbol: preview.symbol)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.title)
                    .lineLimit(1)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(preview.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 184, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.green.opacity(0.52), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 13, y: 7)
        .rotationEffect(.degrees(-1.5))
        .scaleEffect(1.03)
    }
}

private struct SidebarTabRow: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let isDropTargeted: Bool
    let isDragging: Bool
    let suppressActivation: Bool
    let beginDrag: (BrowserDragPayload) -> Void
    let dragChanged: (SidebarDropTarget, CGPoint) -> Void
    let finishDrag: (SidebarDropTarget, CGPoint) -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isSelected: Bool {
        tab.id == store.selectedTabID
    }

    private var showsCloseButton: Bool {
        isSelected || isHovering || isFocused
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            TabFavicon(address: tab.address, isSuspended: tab.isSuspended, isPinned: tab.isPinned)
                .frame(width: 14, height: 14)
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular, design: .rounded))
            Spacer(minLength: 0)
        }
    }

    private var closeButton: some View {
        Button { store.requestClose(tab.id) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
            .buttonStyle(.plain)
            .pointerCursor()
            .opacity(showsCloseButton ? 0.7 : 0)
            .allowsHitTesting(showsCloseButton)
            .accessibilityLabel("Close \(tab.title)")
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { if !suppressActivation { store.select(tab.id) } } label: { rowContent }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.11))
            }
        }
        .interactiveHover(cornerRadius: 9)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isDropTargeted ? Color.green.opacity(0.72) : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .sidebarDropTarget(.tab(tab.id))
        .sidebarDragGesture(payload: .tab(tab.id), source: .tab(tab.id), began: beginDrag, changed: dragChanged, ended: finishDrag)
        .opacity(store.isClosingTab(tab.id) ? 0 : (isDragging ? 0.42 : 1))
        .scaleEffect(store.isClosingTab(tab.id) ? 0.82 : (isDragging ? 0.98 : 1), anchor: .trailing)
        .blur(radius: store.isClosingTab(tab.id) ? 3 : 0)
        .offset(x: store.isClosingTab(tab.id) ? 14 : 0)
        .animation(.easeIn(duration: 0.16), value: store.isClosingTab(tab.id))
        .animation(.spring(duration: 0.18, bounce: 0.12), value: isDropTargeted)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96)),
            removal: .opacity.combined(with: .scale(scale: 0.84, anchor: .trailing))
        ))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Unpin tab" : "Pin tab") { store.togglePinned(tab.id) }
            TabBookmarkFolderMenu(store: store, tabID: tab.id)
        }
    }
}

private struct TabBookmarkFolderMenu: View {
    @ObservedObject var store: BrowserStore
    let tabID: UUID

    var body: some View {
        Menu("Save page to folder") {
            ForEach(store.visibleBookmarkFolders) { folder in
                Button(folder.name) { store.saveTab(tabID, to: folder.id) }
            }
        }
    }
}

private struct TabFavicon: View {
    let address: URL
    let isSuspended: Bool
    let isPinned: Bool
    let fallbackSymbol: String

    init(address: URL, isSuspended: Bool, isPinned: Bool, fallbackSymbol: String = "globe") {
        self.address = address
        self.isSuspended = isSuspended
        self.isPinned = isPinned
        self.fallbackSymbol = fallbackSymbol
    }

    var body: some View {
        if isSuspended {
            Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
        } else if isPinned {
            Image(systemName: "pin.fill").foregroundStyle(.green)
        } else if let faviconURL {
            AsyncImage(url: faviconURL, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: fallbackSymbol).foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: fallbackSymbol).foregroundStyle(.secondary)
        }
    }

    private var faviconURL: URL? {
        guard let host = address.host else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }
}

struct ChromeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? Color.primary.opacity(0.13) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .pointerCursor()
    }
}

struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

extension View {
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }

    func interactiveHover(cornerRadius: CGFloat) -> some View {
        modifier(InteractiveHoverModifier(cornerRadius: cornerRadius))
    }
}

private struct InteractiveHoverModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovering ? 0.075 : 0))
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct SuspendedTabView: View {
    let tab: BrowserTab
    let resume: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let preview = tab.preview {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 700, maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 12, y: 6)
            } else {
                Image(systemName: "moon.zzz.fill").font(.system(size: 44)).foregroundStyle(.green)
            }
            Text(tab.title).font(.title3.weight(.medium))
            Text("This tab was paused to free memory.").foregroundStyle(.secondary)
            Button("Resume tab", action: resume).buttonStyle(.borderedProminent).tint(.green)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CommandPalette: View {
    @ObservedObject var store: BrowserStore
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Command center", systemImage: "command")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text("ESC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, open a tab, or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .onSubmit { search() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            paletteSection("ACTIONS") {
                command("New tab", symbol: "plus.square.on.square", shortcut: "⌘T") { store.createTab() }
                command("Back", symbol: "chevron.left", shortcut: "⌘←") { store.goBack() }
                command("Forward", symbol: "chevron.right", shortcut: "⌘→") { store.goForward() }
                command("Copy active tab URL", symbol: "link", shortcut: "⌘⇧C") { store.copySelectedTabAddress() }
                command("Reload page", symbol: "arrow.clockwise", shortcut: "⌘R") { store.reloadSelectedTab() }
                command("Reload ignoring cache", symbol: "arrow.clockwise", shortcut: "⌘⇧R") {
                    store.reloadSelectedTabIgnoringCache()
                }
                command("Show history", symbol: "clock.arrow.circlepath", shortcut: "⌘J") { store.isHistoryPresented = true }
                command("Show downloads", symbol: "arrow.down.circle", shortcut: "⌘Y") { store.isDownloadsPresented = true }
                command("Cycle open tabs", symbol: "rectangle.3.group", shortcut: "⌃⇥") {
                    store.selectPreviouslySelectedTab()
                }
                command("Toggle tab pin", symbol: "pin", shortcut: "") {
                    if let tabID = store.selectedTabID { store.togglePinned(tabID) }
                }
                command("Toggle sidebar", symbol: "sidebar.left", shortcut: "⌘B") { store.toggleSidebar() }
                command("Browser settings", symbol: "gearshape", shortcut: "⌘,") { store.isSettingsPresented = true }
            }

            if !store.visibleTabs.isEmpty {
                paletteSection("OPEN TABS") {
                    ForEach(store.visibleTabs.prefix(5)) { tab in
                        Button { store.select(tab.id); dismiss() } label: {
                            Label(tab.title, systemImage: tab.isSuspended ? "moon.zzz" : "globe")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
        }
        .frame(width: 520)
        .padding(14)
        .background(.regularMaterial)
    }

    private func command(_ title: String, symbol: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button { action(); dismiss() } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(shortcut).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func paletteSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content()
        }
    }

    private func search() { store.navigate(to: query); dismiss() }
}
