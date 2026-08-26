import AppKit
import SwiftUI

struct BrowserWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var store = BrowserStore()
    @State private var addressInput = ""

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
                    .background(Color(nsColor: WebViewPool.contentBackground(isDark: colorScheme == .dark)))
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
        configuredWorkspaceLayout
        .onReceive(NotificationCenter.default.publisher(for: .jungleNewTab)) { _ in store.createTab() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleCloseTab)) { _ in store.closeSelectedTab() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleCommandPalette)) { _ in
            store.isCommandPalettePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleOpenSettings)) { _ in
            store.isSettingsPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleGoBack)) { _ in store.goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleGoForward)) { _ in store.goForward() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleReload)) { _ in store.reloadSelectedTab() }
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

    private var workspaceWithMediaAndDeveloperCommands: some View {
        workspaceWithNotifications
        .onReceive(NotificationCenter.default.publisher(for: .jungleReloadIgnoringCache)) { _ in store.reloadSelectedTabIgnoringCache() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleTogglePictureInPicture)) { _ in store.togglePictureInPicture() }
        .onReceive(NotificationCenter.default.publisher(for: .junglePictureInPictureDidExit)) { notification in
            guard let tabID = notification.userInfo?["tabID"] as? UUID else { return }
            store.restoreTabFromPictureInPicture(tabID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .jungleToggleWebInspector)) { _ in store.toggleWebInspector() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleShowJavaScriptConsole)) { _ in store.showJavaScriptConsole() }
    }

    private var workspaceWithKeyboardHandling: some View {
        workspaceWithMediaAndDeveloperCommands
        .onKeyPress(.return, action: dismissTabPreviewIfPresented)
        .onKeyPress(.escape, action: dismissTabPreviewIfPresented)
        .onOpenURL { store.openExternalURL($0) }
        .sheet(isPresented: $store.isCommandPalettePresented) { CommandPalette(store: store) }
        .sheet(isPresented: $store.isSettingsPresented) { BrowserSettingsView(settings: store.settings, store: store) }
    }

    @ViewBuilder
    private var browserContent: some View {
        if let tab = store.selectedTab {
            ZStack(alignment: .bottomTrailing) {
                if tab.isSuspended {
                    SuspendedTabView(tab: tab, resume: { store.select(tab.id) })
                } else {
                    BrowserWebView(store: store, tab: tab, profile: store.activeProfile)
                        .id(tab.id)
                }

                if store.isSelectedTabLoading {
                    NavigationFeedback(title: tab.address.host ?? "Loading page")
                        .padding(18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.16), value: store.isSelectedTabLoading)
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
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            trafficLightProfileRow
            sidebarHeader
            navigationBar
            quickAccess

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.bookmarkFolders.filter { !$0.isQuickAccess }) { folder in
                        bookmarkFolder(folder)
                    }

                    if !store.bookmarkFolders.filter({ !$0.isQuickAccess }).isEmpty {
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
                    }
                    openTabsHeader
                    ForEach(store.visibleTabs.filter { !$0.isPinned }) { tab in tabRow(tab) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })

            sidebarFooter
                .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
        }
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
                Image(systemName: store.isSelectedTabLoading ? "arrow.triangle.2.circlepath" : "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isSelectedTabLoading ? Color.green : Color.secondary)
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
                    if let folder = store.bookmarkFolders.first(where: \.isQuickAccess) {
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
                ForEach(quickAccessBookmarks) { bookmark in
                    Button { store.openBookmark(bookmark) } label: {
                        TabFavicon(address: bookmark.address, isSuspended: false, isPinned: false, fallbackSymbol: bookmark.symbol)
                            .frame(width: 20, height: 20)
                            .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .interactiveHover(cornerRadius: 11)
                    .help(bookmark.title)
                    .accessibilityLabel(bookmark.title)
                    .contextMenu {
                        Button("Remove from Quick Access", role: .destructive) {
                            guard let folderID = store.bookmarkFolders.first(where: \.isQuickAccess)?.id else { return }
                            store.deleteBookmark(bookmark.id, from: folderID)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var quickAccessBookmarks: [BrowserBookmark] {
        Array(store.bookmarkFolders.first(where: \.isQuickAccess)?.bookmarks.prefix(6) ?? [])
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
            columnCount = (count + 1) / 2
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
            .background(.clear, in: RoundedRectangle(cornerRadius: 9))
            .interactiveHover(cornerRadius: 9)
            .contextMenu {
                Button("Save current page") { store.saveCurrentPage(to: folder.id) }
                Button("Delete folder", role: .destructive) { store.deleteFolder(folder.id) }
            }
            if folder.isExpanded {
                ForEach(folder.bookmarks) { bookmark in
                    Button { store.openBookmark(bookmark) } label: {
                        HStack(spacing: 8) {
                            TabFavicon(address: bookmark.address, isSuspended: false, isPinned: false, fallbackSymbol: bookmark.symbol)
                                .frame(width: 14, height: 14)
                            Text(bookmark.title)
                                .lineLimit(1)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .interactiveHover(cornerRadius: 8)
                    .contextMenu {
                        Button("Remove bookmark", role: .destructive) { store.deleteBookmark(bookmark.id, from: folder.id) }
                    }
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
        SidebarTabRow(store: store, tab: tab)
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

}

private struct SidebarTabRow: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isSelected: Bool {
        tab.id == store.selectedTabID
    }

    private var showsCloseButton: Bool {
        isSelected || isHovering || isFocused
    }

    var body: some View {
        HStack(spacing: 8) {
            TabFavicon(address: tab.address, isSuspended: tab.isSuspended, isPinned: tab.isPinned)
                .frame(width: 14, height: 14)
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular, design: .rounded))
            Spacer(minLength: 0)
            Button { store.close(tab.id) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain)
                .pointerCursor()
                .opacity(showsCloseButton ? 0.7 : 0)
                .allowsHitTesting(showsCloseButton)
                .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.11))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.green.opacity(0.82))
                            .frame(width: 3)
                            .padding(.vertical, 6)
                            .padding(.leading, 4)
                    }
            }
        }
        .interactiveHover(cornerRadius: 9)
        .onTapGesture { store.select(tab.id) }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Unpin tab" : "Pin tab") { store.togglePinned(tab.id) }
            Menu("Save page to folder") {
                ForEach(store.bookmarkFolders) { folder in
                    Button(folder.name) { store.saveCurrentPage(to: folder.id) }
                }
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

private struct ChromeIconButtonStyle: ButtonStyle {
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
                command("Back", symbol: "chevron.left", shortcut: "⌘[") { store.goBack() }
                command("Forward", symbol: "chevron.right", shortcut: "⌘]") { store.goForward() }
                command("Reload page", symbol: "arrow.clockwise", shortcut: "⌘R") { store.reloadSelectedTab() }
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
