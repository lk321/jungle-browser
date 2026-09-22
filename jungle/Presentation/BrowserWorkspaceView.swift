import AppKit
import SwiftUI

struct BrowserWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var store = BrowserStore()
    @State private var addressInput = ""

    private var usesDarkContent: Bool {
        store.settings.appearance.usesDarkContent(systemIsDark: colorScheme == .dark)
    }

    private var sidebarStep: SidebarStep {
        SidebarStep.nearest(to: store.settings.sidebarWidth)
    }

    var body: some View {
        workspaceWithKeyboardHandling
    }

    private var workspaceLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    BrowserSidebar(store: store, addressInput: $addressInput)
                        .environment(\.sidebarStep, sidebarStep)
                        .frame(width: sidebarStep.width)
                        .background(SidebarSurface())
                        .overlay(alignment: .trailing) { SidebarResizeHandle(store: store) }
                        // Sliding only. A behind-window material is drawn by the window server,
                        // which cannot blend it: the moment SwiftUI faded the sidebar, the glass
                        // dropped out whole and the desktop showed through the hole it left.
                        .transition(.move(edge: .leading))
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
            addressInput = store.selectedTabAddressText
            store.beginMemoryHousekeeping()
            ContentBlocking.shared.start()
            applyAdBlockingOptions(store.settings.adBlocking)
            ApplicationIconController.update(for: store.settings.appearance)
            publishTrafficLightsVisibility()
        }
        .onChange(of: store.settings.adBlocking) { _, options in
            applyAdBlockingOptions(options)
        }
        .onChange(of: store.settings.appearance) { _, appearance in
            ApplicationIconController.update(for: appearance)
        }
        .onChange(of: colorScheme) { _, _ in
            ApplicationIconController.update(for: store.settings.appearance)
        }
        .onChange(of: store.isSidebarVisible) { _, _ in publishTrafficLightsVisibility() }
        .onChange(of: store.selectedTabID) { _, _ in
            addressInput = store.selectedTabAddressText
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
        .onReceive(NotificationCenter.default.publisher(for: .jungleOpenQuickAccess)) { notification in
            guard let number = notification.userInfo?["number"] as? Int else { return }
            store.openQuickAccessBookmark(number: number)
        }
    }

    private var workspaceWithPrimaryCommands: some View {
        configuredWorkspaceLayout
        .onReceive(NotificationCenter.default.publisher(for: .jungleNewTab)) { _ in store.createTab() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleFocusTab)) { notification in
            guard let tabID = notification.userInfo?["tabID"] as? UUID else { return }
            store.select(tabID)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .jungleZoomIn)) { _ in store.zoomIn() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleZoomOut)) { _ in store.zoomOut() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleActualSize)) { _ in store.resetPageZoom() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleTogglePictureInPicture)) { _ in store.togglePictureInPicture() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleFindInPage)) { _ in store.presentFindInPage() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleFindNext)) { _ in store.findInPage.next() }
        .onReceive(NotificationCenter.default.publisher(for: .jungleFindPrevious)) { _ in store.findInPage.previous() }
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

                    if tab.isNativeNewTab {
                        NativeNewTabView(store: store)
                    }

                    if !tab.isNativeNewTab && !tab.isSuspended && !store.selectedTabInitialContentIsReady {
                        Color(nsColor: WebViewPool.contentBackground(isDark: usesDarkContent))
                            .allowsHitTesting(false)
                    }

                    if tab.isSuspended {
                        SuspendedTabView(tab: tab, resume: { store.select(tab.id) })
                            .background(Color(nsColor: WebViewPool.contentBackground(isDark: usesDarkContent)))
                    }

                    if let failure = store.selectedNavigationFailure, !tab.isSuspended, !tab.isNativeNewTab {
                        NavigationFailureView(failure: failure, isRetrying: store.isSelectedTabLoading) {
                            store.reloadSelectedTab()
                        }
                        .background(Color(nsColor: WebViewPool.contentBackground(isDark: usesDarkContent)))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    VStack(alignment: .trailing, spacing: 8) {
                        if let copiedAddress = store.copiedTabAddress {
                            CopiedAddressFeedback(address: copiedAddress)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let zoom = store.pageZoomFeedback {
                            PageZoomFeedback(level: zoom)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        if store.isSelectedTabLoading {
                            NavigationFeedback(title: tab.address.host ?? "Loading page")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(18)
                }
                // The window has no titlebar, so the top of the page doubles as one. It takes
                // no space and hands its clicks back to the page, so nothing here moves.
                .overlay(alignment: .top) {
                    ContentHeaderDragArea()
                        .frame(height: ContentHeaderDragArea.height)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topTrailing) {
                    FindInPageOverlay(
                        store: store,
                        sidebarShortcutHint: store.isSidebarShortcutHintVisible ? store.isSidebarVisible : nil
                    )
                }
                .animation(.easeOut(duration: 0.16), value: store.isSelectedTabLoading)
                .animation(.easeOut(duration: 0.16), value: store.copiedTabAddress)
                .animation(.spring(duration: 0.26, bounce: 0.2), value: store.pageZoomFeedback)
                .animation(.easeOut(duration: 0.2), value: store.selectedNavigationFailure)
            }
            .animation(.spring(duration: 0.28, bounce: 0.16), value: store.selectedTabIsLocalDevelopment)
            .opacity(store.isClosingTab(tab.id) ? 0.08 : 1)
            .scaleEffect(store.isClosingTab(tab.id) ? 0.985 : 1)
            .blur(radius: store.isClosingTab(tab.id) ? 1.5 : 0)
            .animation(.easeIn(duration: 0.16), value: store.isClosingTab(tab.id))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Carries the user's blocker switches to the two places that act on them: the rule lists
    /// WebKit applies per tab, and the scripts a tab runs in the page.
    private func applyAdBlockingOptions(_ options: AdBlockingOptions) {
        ContentBlocking.shared.setBlocking(
            adsAndTrackers: options.blocksAdsAndTrackers,
            hidesAdSpace: options.hidesBlockedAdSpace
        )
        WebViewPool.shared.setAdBlockingOptions(options)
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

private struct NativeNewTabView: View {
    @ObservedObject var store: BrowserStore
    @State private var query = ""
    @State private var highlightedSuggestionID: String?
    /// Backspacing must not re-complete what the user just deleted.
    @State private var isDeletingInput = false
    @State private var searchFieldHeight: CGFloat = 0
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            // One ranking pass per render: the gate, the rows and the ghost text all read it.
            let suggestions = visibleSuggestions
            let completion = isDeletingInput ? nil : BrowserStore.inlineCompletion(for: query, in: suggestions)
            VStack(spacing: 0) {
                Spacer(minLength: max(44, proxy.size.height * 0.16))

                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.green.gradient)
                            .frame(width: 82, height: 82)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(.white.opacity(0.18)))
                        Text("Jungle")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("A calm place to start browsing")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search or enter a full URL", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .focused($isSearchFieldFocused)
                            .onSubmit(openInput)
                            .overlay(alignment: .leading) {
                                inlineCompletionGhost(completion, typed: query, size: 16)
                            }
                            .onKeyPress(.downArrow) { moveHighlight(by: 1, in: suggestions) }
                            .onKeyPress(.upArrow) { moveHighlight(by: -1, in: suggestions) }
                            .onKeyPress(.escape) {
                                guard !query.isEmpty else { return .ignored }
                                highlightedSuggestionID = nil
                                query = ""
                                return .handled
                            }
                            .onChange(of: query) { previous, current in
                                isDeletingInput = current.count < previous.count
                                highlightedSuggestionID = nil
                            }
                        Button(action: openInput) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Open search or address")
                    }
                    .padding(8)
                    .padding(.leading, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.18)))
                    .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
                    // Hung under the field by its measured height: the list appears over the
                    // page instead of growing the card and pushing everything under it down.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchFieldHeight = $0 }
                    .overlay(alignment: .topLeading) {
                        if !suggestions.isEmpty {
                            suggestionPanel(suggestions)
                                .offset(y: searchFieldHeight + 8)
                        }
                    }
                    .zIndex(1)

                    HStack(spacing: 8) {
                        Label("Searches use \(store.settings.searchEngine.title)", systemImage: "sparkle.magnifyingglass")
                        Text("•")
                        Text("Full URLs open directly")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 580)
                .padding(.horizontal, 28)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LinearGradient(
                    colors: [Color.green.opacity(0.15), Color.indigo.opacity(0.06), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            isSearchFieldFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jungle new tab page")
    }

    /// At most the seven rows the store ranks, so no scroll view: inside an overlay one is
    /// proposed the field's height and the rows under the first stop taking clicks.
    private func suggestionPanel(_ suggestions: [SmartAddressSuggestion]) -> some View {
        VStack(spacing: 2) {
            ForEach(suggestions) { suggestion in
                suggestionRow(suggestion)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openInput() {
        let suggestions = visibleSuggestions
        if let highlighted = suggestions.first(where: { $0.id == highlightedSuggestionID }) {
            store.navigate(to: highlighted.input)
            return
        }
        // With nothing highlighted, Return accepts the ghost completion and otherwise opens
        // exactly what was typed.
        let completion = isDeletingInput ? nil : BrowserStore.inlineCompletion(for: query, in: suggestions)
        let input = completion ?? query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            isSearchFieldFocused = true
            return
        }
        store.navigate(to: input)
    }

    private var visibleSuggestions: [SmartAddressSuggestion] {
        store.smartAddressSuggestions(for: query)
    }

    private func moveHighlight(by step: Int, in suggestions: [SmartAddressSuggestion]) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let current = highlightedSuggestionID.flatMap { id in suggestions.firstIndex { $0.id == id } }
        let next = BrowserStore.highlightedSuggestionIndex(from: current, step: step, count: suggestions.count)
        highlightedSuggestionID = next.map { suggestions[$0].id }
        return .handled
    }

    private func suggestionRow(_ suggestion: SmartAddressSuggestion) -> some View {
        Button {
            store.navigate(to: suggestion.input)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: suggestion.symbol)
                    .foregroundStyle(suggestionColor(suggestion))
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .lineLimit(1)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(suggestion.detail)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                highlightedSuggestionID == suggestion.id ? Color.accentColor.opacity(0.22) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(suggestion.accessibilityLabel)
    }

    private func suggestionColor(_ suggestion: SmartAddressSuggestion) -> Color {
        switch suggestion {
        case .direct:
            .green
        case .search:
            .indigo
        case .saved:
            .secondary
        }
    }
}

/// Inline autocomplete, drawn as ghost text: the typed prefix is laid out hidden so the
/// remainder starts exactly where the caret is.
/// ponytail: a real selected suffix inside the field needs an NSTextField representable, which
/// this file deliberately avoids. Return still accepts the completion, which is the behaviour
/// users are after. Upgrade path: wrap NSTextField and set `currentEditor().selectedRange`.
@ViewBuilder
private func inlineCompletionGhost(_ completion: String?, typed: String, size: CGFloat) -> some View {
    if let completion, completion.count > typed.count {
        HStack(spacing: 0) {
            Text(typed).hidden()
            Text(String(completion.dropFirst(typed.count))).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.system(size: size, weight: .medium, design: .rounded))
        .lineLimit(1)
        .allowsHitTesting(false)
    }
}

private struct SidebarSurface: View {
    var body: some View {
        SidebarGlass()
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

/// Observes the find session on its own, so each keystroke redraws the bar and not the page.
/// The page's top-right corner: the find bar, and under it the ⌘B hint.
private struct FindInPageOverlay: View {
    let store: BrowserStore
    /// Whether the sidebar is showing, while the hint is up; nil when it is not.
    let sidebarShortcutHint: Bool?
    @ObservedObject private var find: FindInPage

    init(store: BrowserStore, sidebarShortcutHint: Bool?) {
        self.store = store
        self.sidebarShortcutHint = sidebarShortcutHint
        find = store.findInPage
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if find.isPresented {
                FindInPageBar(find: find, dismiss: store.dismissFindInPage)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let sidebarIsVisible = sidebarShortcutHint {
                SidebarShortcutHint(hidesSidebar: sidebarIsVisible)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, ContentHeaderDragArea.height + 4)
        .padding(.trailing, 8)
        .animation(.spring(duration: 0.24, bounce: 0.18), value: find.isPresented)
        .animation(.spring(duration: 0.24, bounce: 0.18), value: sidebarShortcutHint)
    }
}

private struct SidebarShortcutHint: View {
    let hidesSidebar: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Press \(Text("⌘B").fontWeight(.bold)) again to \(hidesSidebar ? "hide" : "show") the sidebar")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Text("This page uses ⌘B for itself")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        // The window's colour, not a material, for the reason the find bar above it gives.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.14)))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

private struct PageZoomFeedback: View {
    let level: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: level > 1 ? "plus.magnifyingglass" : (level < 1 ? "minus.magnifyingglass" : "1.magnifyingglass"))
                .foregroundStyle(.secondary)
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
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

    @State private var isStackListPresented = false

    private var metrics: DeveloperMetrics? { store.selectedDeveloperMetrics }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Label("Local", systemImage: "hammer.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .help("This tab is served from your machine")

                Text(tab.address.host ?? "Local development")
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Divider().frame(height: 18)

                // Every chip is as wide as what it holds, so a short stack name leaves no gap
                // before the metrics. The row glides to its new width when a payload lands
                // rather than jumping, which is what a reflow made unpleasant before.
                HStack(spacing: 6) {
                    technologyGroup
                    metric("Load", value: durationDescription(metrics?.loadDurationMilliseconds), help: "Navigation timing reported by the page")
                    metric("Req", value: metrics.map { "\($0.requestCount)" } ?? "—", help: "Main navigation plus resource timing entries observed while loading")
                    metric("Data", value: metrics.map { ByteCountFormatter.string(fromByteCount: $0.transferredBytes, countStyle: .file) } ?? "—", help: "Transferred resource bytes reported by the page")

                    if let repeated = metrics?.repeatedRequestCount, repeated > 0 {
                        Label("\(repeated) repeated", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .help("Resources requested more than once during this load")
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: metrics)

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
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(help)
    }

    /// The strongest detection leads; the rest wait in a popover. The chip is only as wide
    /// as the name it shows: a 120pt floor is what left a gap before the metrics.
    private var technologyGroup: some View {
        technologyContent(metrics?.technologies ?? [])
    }

    @ViewBuilder
    private func technologyContent(_ technologies: [DetectedTechnology]) -> some View {
        if let primary = technologies.first {
            let extra = technologies.count - 1
            if extra > 0 {
                Button { isStackListPresented.toggle() } label: {
                    technologyChip(primary, extra: extra)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .popover(isPresented: $isStackListPresented, arrowEdge: .bottom) {
                    technologyList(technologies)
                }
                .accessibilityLabel("Detected stack: \(technologies.map(\.name).joined(separator: ", "))")
                .accessibilityHint("Shows every framework detected on this page")
            } else {
                technologyChip(primary, extra: 0)
            }
        } else {
            metric("Stack", value: "—", help: "Frameworks detected on this page")
        }
    }

    private func technologyChip(_ technology: DetectedTechnology, extra: Int) -> some View {
        HStack(spacing: 5) {
            Text(technology.name.prefix(1))
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .frame(width: 16, height: 16)
                .background(Color.green.opacity(0.22), in: Circle())
            Text(technology.name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            if extra > 0 {
                // A count on its own reads as a status; the chevron is what says "this opens".
                HStack(spacing: 2) {
                    Text("+\(extra)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .black))
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.18), in: Capsule())
            }
        }
        .foregroundStyle(.green)
        .padding(.leading, 3)
        .padding(.trailing, extra > 0 ? 4 : 8)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.10), in: Capsule())
        .help(extra > 0 ? "Detected from \(technology.detail). Click for \(extra) more" : "Detected from \(technology.detail)")
        .accessibilityLabel("\(technology.name), detected from \(technology.detail)")
    }

    private func technologyList(_ technologies: [DetectedTechnology]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected stack")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(technologies, id: \.name) { technology in
                HStack(alignment: .top, spacing: 8) {
                    Text(technology.name.prefix(1))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.green)
                        .frame(width: 18, height: 18)
                        .background(Color.green.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(technology.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text("From \(technology.detail)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
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
    @State private var profileMenuWidth: CGFloat = 0
    @State private var iconPickerTarget: QuickAccessIconTarget?
    @State private var hoveredQuickAccessBookmarkID: UUID?
    @State private var highlightedSuggestionID: String?
    /// Backspacing must not re-complete what the user just deleted.
    @State private var isDeletingInput = false
    @State private var addressFieldHeight: CGFloat = 0
    @FocusState private var isAddressFocused: Bool
    @Environment(\.sidebarStep) private var step

    private var selectedTabIsNativeNewTab: Bool {
        store.selectedTab?.isNativeNewTab == true
    }

    private var addressBarSymbol: String {
        if selectedTabIsNativeNewTab { return "leaf.fill" }
        return store.selectedTabUsesInsecureHTTP ? "lock.slash.fill" : "lock.fill"
    }

    private var addressBarColor: Color {
        if selectedTabIsNativeNewTab { return .green }
        return store.selectedTabUsesInsecureHTTP ? .red : .secondary
    }

    private var addressBarAccessibilityLabel: String {
        if selectedTabIsNativeNewTab { return "Jungle new tab page" }
        return store.selectedTabUsesInsecureHTTP ? "Not secure connection" : "Secure connection"
    }

    private var addressBarHelp: String {
        if selectedTabIsNativeNewTab { return "Jungle's native new tab page" }
        return store.selectedTabUsesInsecureHTTP ? "This page uses an insecure HTTP connection" : "Secure HTTPS connection"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: step.showsLabels ? 12 : 10) {
            trafficLightProfileRow
            sidebarHeader
            navigationBar
                .zIndex(1)
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

                    let pinnedTabs = store.listedTabs.filter(\.isPinned)
                    if !pinnedTabs.isEmpty {
                        sidebarLabel("PINNED", symbol: "pin.fill")
                        ForEach(pinnedTabs) { tab in tabRow(tab) }
                        if draggedTabIsPinned {
                            tabAppendDropTarget(isPinned: true)
                        }
                    }
                    openTabsHeader
                    ForEach(store.listedTabs.filter { !$0.isPinned }) { tab in tabRow(tab) }
                    if draggedItem?.kind == .tab, !draggedTabIsPinned {
                        tabAppendDropTarget(isPinned: false)
                    }
                    if draggedItem?.kind == .bookmark || completedDropTarget == .removal {
                        bookmarkRemovalDropZone
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.26, bounce: 0.16), value: store.listedTabs.map(\.id))
                .animation(.easeOut(duration: 0.16), value: store.closingTabIDs)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })

            sidebarFooter
                .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
        }
        .coordinateSpace(name: SidebarDragSpace.name)
        // This sidebar leaves the view tree while it is hidden, so it catches up on the way in.
        .task { addressInput = store.selectedTabAddressText }
        // Same-document navigations now rewrite the address as the user browses, so the field
        // follows the page only while nobody is typing into it.
        .onChange(of: store.selectedTab?.address) { _, _ in
            guard !isAddressFocused else { return }
            addressInput = store.selectedTabAddressText
        }
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

    @ViewBuilder
    private var sidebarHeader: some View {
        Group {
            if step.showsLabels {
                HStack {
                    toggleSidebarButton
                    Spacer(minLength: 0)
                    backButton
                    forwardButton
                    reloadButton
                }
            } else {
                // Four 30pt buttons never fit on one compact row, so they wrap into a 2x2 block,
                // centred on the same axis as the search button under it.
                VStack(spacing: 6) {
                    HStack(spacing: 6) { toggleSidebarButton; reloadButton }
                    HStack(spacing: 6) { backButton; forwardButton }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, step.showsLabels ? 12 : 10)
        .padding(.top, 8)
        .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
    }

    private var toggleSidebarButton: some View {
        Button(action: {
            dismissAddressFocus()
            store.toggleSidebar()
        }) { Image(systemName: "sidebar.left") }
            .buttonStyle(ChromeIconButtonStyle())
            .accessibilityLabel("Toggle sidebar")
    }

    private var backButton: some View {
        chromeButton("chevron.left", label: "Back", action: store.goBack)
    }

    private var forwardButton: some View {
        chromeButton("chevron.right", label: "Forward", action: store.goForward)
    }

    private var reloadButton: some View {
        chromeButton(store.isSelectedTabLoading ? "xmark" : "arrow.clockwise", label: store.isSelectedTabLoading ? "Stop loading" : "Refresh") {
            if store.isSelectedTabLoading { store.stopLoadingSelectedTab() } else { store.reloadSelectedTab() }
        }
    }

    private var trafficLightProfileRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            profilePicker
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { profileMenuWidth = $0 }
        }
        // The traffic lights own the top-left corner. Wide enough, the picker simply clears them
        // on the right; compact has to drop below them instead.
        .padding(.top, step == .compact ? 30 : 8)
        .frame(maxWidth: .infinity)
        // The empty header beside the traffic lights is the only surface that drags the window.
        // A background never changes layout, and stopping short of the profile menu keeps that
        // control's clicks a matter of geometry rather than of hit testing order.
        .background(alignment: .leading) {
            WindowHeaderDragArea()
                .padding(.trailing, profileMenuWidth)
                .accessibilityHidden(true)
        }
        .simultaneousGesture(TapGesture().onEnded { dismissAddressFocus() })
    }

    private var navigationBar: some View {
        // One ranking pass per render: the gate, the rows and the ghost text all read it.
        let suggestions = isAddressFocused ? store.smartAddressSuggestions(for: addressInput) : []
        let completion = isDeletingInput ? nil : BrowserStore.inlineCompletion(for: addressInput, in: suggestions)

        return Group {
            if step.showsLabels {
                addressField(suggestions, completion: completion)
            } else {
                compactSearchButton
            }
        }
        // Placed by the field's measured height rather than by an alignment guide: a guide set
        // inside an `if` is not forwarded out of the conditional, which parked the list on top
        // of the field and covered what was being typed.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { addressFieldHeight = $0 }
        .overlay(alignment: .topLeading) {
            if !suggestions.isEmpty {
                addressSuggestions(suggestions)
                    .offset(y: addressFieldHeight + 6)
            }
        }
        .padding(.horizontal, step.showsLabels ? 12 : 10)
    }

    private func addressField(_ suggestions: [SmartAddressSuggestion], completion: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: addressBarSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(addressBarColor)
                .accessibilityLabel(addressBarAccessibilityLabel)
                .help(addressBarHelp)
            TextField("Search or enter address", text: $addressInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .focused($isAddressFocused)
                .onSubmit { openAddressInput(suggestions, completion: completion) }
                .overlay(alignment: .leading) {
                    inlineCompletionGhost(completion, typed: addressInput, size: 13)
                }
                .onKeyPress(.downArrow) { moveHighlight(by: 1, in: suggestions) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1, in: suggestions) }
                .onKeyPress(.escape) {
                    highlightedSuggestionID = nil
                    addressInput = store.selectedTabAddressText
                    dismissAddressFocus()
                    return .handled
                }
                .onChange(of: addressInput) { previous, current in
                    isDeletingInput = current.count < previous.count
                    highlightedSuggestionID = nil
                }
            if store.isSelectedTabLoading { ProgressView().controlSize(.mini).tint(.green) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// ponytail: compact trades the field for a widen-on-tap affordance. Focusing the field in
    /// the same frame it is created does not stick, and chasing it is not worth a phase.
    /// A chrome-sized button also reads as one of the buttons above it, where a full-width
    /// empty pill read as a text field that had lost its text.
    private var compactSearchButton: some View {
        Button(action: growToShowAddressField) {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(ChromeIconButtonStyle())
        .frame(maxWidth: .infinity)
        .help("Search or enter address")
        .accessibilityLabel("Search or enter address")
    }

    /// Return opens the highlighted row, then the ghost completion, then the raw text.
    private func openAddressInput(_ suggestions: [SmartAddressSuggestion], completion: String?) {
        let highlighted = suggestions.first { $0.id == highlightedSuggestionID }
        store.navigate(to: highlighted?.input ?? completion ?? addressInput)
        highlightedSuggestionID = nil
        dismissAddressFocus()
    }

    private func moveHighlight(by step: Int, in suggestions: [SmartAddressSuggestion]) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let current = highlightedSuggestionID.flatMap { id in suggestions.firstIndex { $0.id == id } }
        let next = BrowserStore.highlightedSuggestionIndex(from: current, step: step, count: suggestions.count)
        highlightedSuggestionID = next.map { suggestions[$0].id }
        return .handled
    }

    /// Never more than the seven rows the store ranks, so the list is a plain stack: a scroll
    /// view inside an overlay is proposed the field's height, which squashed the rows into it
    /// and left everything below the first one unclickable.
    private func addressSuggestions(_ suggestions: [SmartAddressSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(suggestions) { suggestion in
                Button {
                    addressInput = suggestion.input
                    isAddressFocused = false
                    store.navigate(to: suggestion.input)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: suggestion.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(addressSuggestionColor(suggestion))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title).lineLimit(1).font(.system(size: 12.5, weight: .medium, design: .rounded))
                            Text(suggestion.detail)
                                .lineLimit(1)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let sourceLabel = suggestion.sourceLabel {
                            Text(sourceLabel).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        highlightedSuggestionID == suggestion.id ? Color.accentColor.opacity(0.22) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .interactiveHover(cornerRadius: 8)
                .accessibilityLabel(suggestion.accessibilityLabel)
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
        // The overlay is proposed the field's own height. Without this the panel is laid out
        // inside it and only the first row answers a click.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addressSuggestionColor(_ suggestion: SmartAddressSuggestion) -> Color {
        switch suggestion {
        case .direct:
            .green
        case .search:
            .indigo
        case .saved:
            .secondary
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A header over icon-width tiles is a row of label for no information, so compact
            // drops it. The same actions stay on the grid's context menu at every width.
            if step.showsLabels {
                HStack {
                    sidebarLabel("QUICK ACCESS", symbol: "star.fill")
                    Spacer()
                    Menu {
                        quickAccessActions
                    } label: {
                        Image(systemName: "ellipsis").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Quick Access options")
                    .pointerCursor()
                }
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
        .padding(.horizontal, step.showsLabels ? 12 : 10)
        .contextMenu { quickAccessActions }
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

    @ViewBuilder
    private var quickAccessActions: some View {
        if let folder = quickAccessFolder {
            Button("Save current page") { store.saveCurrentPage(to: folder.id) }
            if !folder.bookmarks.isEmpty { Divider() }
            ForEach(folder.bookmarks) { bookmark in
                Button("Remove \(bookmark.title)", role: .destructive) {
                    store.deleteBookmark(bookmark.id, from: folder.id)
                }
            }
        }
    }

    private var quickAccessBookmarks: [BrowserBookmark] {
        quickAccessFolder?.bookmarks ?? []
    }

    private var quickAccessFolder: BookmarkFolder? {
        store.visibleBookmarkFolders.first(where: \.isQuickAccess)
    }

    private var quickAccessGridColumns: [GridItem] {
        let count = max(quickAccessBookmarks.count, 1)
        let columnCount = min(count, step.quickAccessColumns)
        return Array(repeating: GridItem(.flexible(), spacing: 7), count: columnCount)
    }

    private func bookmarkFolder(_ folder: BookmarkFolder) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { store.toggleFolder(folder.id) } label: {
                HStack(spacing: 6) {
                    if !step.showsLabels { Spacer(minLength: 0) }
                    Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                    if step.showsLabels {
                        Text(folder.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(folder.name)
            .accessibilityLabel(folder.name)
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
                    .labelStyle(SidebarLabelStyle(showsTitle: step.showsLabels))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Settings")
            .accessibilityLabel("Settings")
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
                if step.showsProfileName {
                    Text(store.activeProfile.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("⌃\(store.profiles.firstIndex(of: store.activeProfile).map { $0 + 1 } ?? 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                // The chevron is the widest thing in a 96pt sidebar that says the least.
                if step.showsLabels {
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, step.showsLabels ? 10 : 6)
            .padding(.vertical, step.showsLabels ? 8 : 4)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .padding(.trailing, step.showsLabels ? 12 : 10)
        .pointerCursor()
        .help(store.activeProfile.name)
        .accessibilityLabel("Profile: \(store.activeProfile.name)")
    }

    @ViewBuilder
    private func sidebarLabel(_ title: String, symbol: String) -> some View {
        Group {
            if step.showsLabels {
                Text(title).font(.caption2.weight(.semibold))
            } else {
                Image(systemName: symbol).font(.caption2.weight(.bold))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .help(title.capitalized)
        .accessibilityLabel(title.capitalized)
    }

    private var openTabsHeader: some View {
        HStack(spacing: 0) {
            if step.showsLabels {
                sidebarLabel("OPEN TABS", symbol: "square.on.square")
            }
            Spacer(minLength: 0)
            Button(action: store.createTab) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("New tab")
            .accessibilityLabel("New tab")
            .padding(.trailing, step.showsLabels ? 8 : 0)
            if !step.showsLabels { Spacer(minLength: 0) }
        }
        .padding(.top, step.showsLabels ? 0 : 6)
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        SidebarTabRow(
            store: store,
            tabID: tab.id,
            isDropTargeted: isTabTargeted(tab.id),
            isDragging: draggedItem == .tab(tab.id),
            isActivationSuppressed: { shouldSuppressActivation },
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
        let isOpen = store.quickAccessTabID(for: bookmark.id) != nil
        let isActive = store.isQuickAccessBookmarkActive(bookmark.id)
        let showsClose = isOpen && hoveredQuickAccessBookmarkID == bookmark.id
        // The close control is a sibling of the tile's button, not a button inside its label:
        // a nested button never receives the click.
        return ZStack(alignment: .topTrailing) {
            Button { if !shouldSuppressActivation { store.openQuickAccessBookmark(bookmark) } } label: {
                TabFavicon(address: bookmark.address, isSuspended: false, isPinned: false, fallbackSymbol: bookmark.symbol, customSymbol: bookmark.customSymbol)
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, minHeight: step.showsLabels ? 48 : 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(bookmark.title)
            .accessibilityLabel(bookmark.title)
            .accessibilityValue(isActive ? "Open" : "")

            Button { store.closeQuickAccessBookmark(bookmark.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(.primary.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Close \(bookmark.title)")
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .background(Color.green.opacity(isActive ? 0.11 : 0), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(quickAccessTileStroke(bookmark.id, isActive: isActive), lineWidth: quickAccessTileStrokeWidth(bookmark.id, isActive: isActive))
                .allowsHitTesting(false)
        }
        .pointerCursor()
        .interactiveHover(cornerRadius: 11)
        .onHover { isHovering in
            if isHovering {
                hoveredQuickAccessBookmarkID = bookmark.id
            } else if hoveredQuickAccessBookmarkID == bookmark.id {
                hoveredQuickAccessBookmarkID = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsClose)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .animation(.spring(duration: 0.18, bounce: 0.12), value: activeDropTarget)
        .sidebarDropTarget(.bookmark(bookmarkID: bookmark.id, folderID: folderID))
        .sidebarDragGesture(payload: .bookmark(bookmark.id, folderID: folderID), source: .bookmark(bookmarkID: bookmark.id, folderID: folderID), began: beginDrag, changed: dragChanged, ended: finishDrag)
        .scaleEffect(isBookmarkTargeted(bookmark.id) ? 1.035 : (draggedItem == .bookmark(bookmark.id, folderID: folderID) ? 0.96 : 1))
        .opacity(draggedItem == .bookmark(bookmark.id, folderID: folderID) ? 0.45 : 1)
        .contextMenu {
            Button("Choose icon…") {
                iconPickerTarget = QuickAccessIconTarget(bookmarkID: bookmark.id, folderID: folderID)
            }
            Button("Remove from Quick Access", role: .destructive) { store.deleteBookmark(bookmark.id, from: folderID) }
        }
        .popover(item: iconPickerBinding(for: bookmark.id), arrowEdge: .trailing) { target in
            QuickAccessIconPicker(selection: bookmark.customSymbol) { symbol in
                store.setBookmarkSymbol(symbol, for: target.bookmarkID, in: target.folderID)
                iconPickerTarget = nil
            }
        }
    }

    /// One shared picker state, but only the tile it belongs to presents it: binding every
    /// tile straight to `iconPickerTarget` would pop a popover on all of them at once.
    private func iconPickerBinding(for bookmarkID: UUID) -> Binding<QuickAccessIconTarget?> {
        Binding(
            get: { iconPickerTarget?.bookmarkID == bookmarkID ? iconPickerTarget : nil },
            set: { iconPickerTarget = $0 }
        )
    }

    /// The tile a drop is aimed at keeps the loud green it always had; an open tile gets the
    /// quieter green the selected tab row uses, so the two states stay apart.
    private func quickAccessTileStroke(_ bookmarkID: UUID, isActive: Bool) -> Color {
        if isBookmarkTargeted(bookmarkID) { return Color.green.opacity(0.7) }
        return isActive ? Color.green.opacity(0.5) : .white.opacity(0.10)
    }

    private func quickAccessTileStrokeWidth(_ bookmarkID: UUID, isActive: Bool) -> CGFloat {
        if isBookmarkTargeted(bookmarkID) { return 2 }
        return isActive ? 1.5 : 1
    }

    private func folderBookmarkRow(_ bookmark: BrowserBookmark, folderID: UUID) -> some View {
        Button { if !shouldSuppressActivation { store.openBookmark(bookmark) } } label: {
            HStack(spacing: 8) {
                if !step.showsLabels { Spacer(minLength: 0) }
                TabFavicon(address: bookmark.address, isSuspended: false, isPinned: false, fallbackSymbol: bookmark.symbol, customSymbol: bookmark.customSymbol)
                    .frame(width: 14, height: 14)
                if step.showsLabels {
                    Text(bookmark.title)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(bookmark.title)
            .accessibilityLabel(bookmark.title)
            // The indent that reads as "inside this folder" is wider than a compact row can spare.
            .padding(.leading, step.showsLabels ? 22 : 10)
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
            .labelStyle(SidebarLabelStyle(showsTitle: step.showsLabels))
            .font(.caption.weight(.semibold))
            .foregroundStyle(isRemovalTargeted ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isRemovalTargeted ? Color.red.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isRemovalTargeted ? Color.red.opacity(0.62) : Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: isRemovalTargeted ? 1.5 : 1, dash: [4, 3])))
            .padding(.top, 10)
            .sidebarDropTarget(.removal)
            .help("Drag a saved page here to remove it from its folder or Quick Access")
            .accessibilityLabel("Drop saved page here to remove")
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

    private func growToShowAddressField() {
        withAnimation(.spring(duration: 0.26, bounce: 0.18)) {
            store.settings.sidebarWidth = SidebarStep.regular.width
        }
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
    let tabID: UUID
    let isDropTargeted: Bool
    let isDragging: Bool
    /// Asked at click time. A `Bool` captured at render time stayed `true` after a drag until
    /// something else redrew the list, so the next click on a tab did nothing.
    let isActivationSuppressed: () -> Bool
    let beginDrag: (BrowserDragPayload) -> Void
    let dragChanged: (SidebarDropTarget, CGPoint) -> Void
    let finishDrag: (SidebarDropTarget, CGPoint) -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.sidebarStep) private var step

    /// Read live rather than captured: a row rendering the copy it was built with keeps
    /// showing the pin it no longer has, and keeps offering to unpin it.
    private var tab: BrowserTab? {
        store.tabs.first(where: { $0.id == tabID })
    }

    private var isSelected: Bool {
        tabID == store.selectedTabID
    }

    private var showsCloseButton: Bool {
        isSelected || isHovering || isFocused
    }

    private var isMuted: Bool { store.isMuted(tabID) }

    /// The speaker earns its place only while the tab makes sound, or while it is the reason
    /// the tab is silent.
    private var showsSpeaker: Bool {
        store.isAudible(tabID) || isMuted
    }

    private func rowContent(_ tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            if !step.showsLabels { Spacer(minLength: 0) }
            TabFavicon(address: tab.address, isSuspended: tab.isSuspended, isPinned: tab.isPinned)
                .frame(width: 14, height: 14)
            if step.showsLabels {
                Text(tab.title)
                    .lineLimit(1)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular, design: .rounded))
            }
            Spacer(minLength: 0)
        }
        .help(tab.title)
        .accessibilityLabel(tab.title)
    }

    private var speakerButton: some View {
        Button { store.toggleMuted(tabID) } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 14, height: 14)
                .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                .contentTransition(.symbolEffect(.replace))
                // Without this the button only answers clicks that land on the glyph's own
                // strokes, which at 9pt is a sliver the pointer keeps missing.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .opacity(showsSpeaker ? 1 : 0)
        .allowsHitTesting(showsSpeaker)
        .frame(width: showsSpeaker ? 14 : 0)
        .help(isMuted ? "Unmute tab" : "Mute tab")
        .accessibilityLabel(isMuted ? "Unmute tab" : "Mute tab")
    }

    private func closeButton(_ tab: BrowserTab) -> some View {
        Button { store.requestClose(tabID) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
            .buttonStyle(.plain)
            .pointerCursor()
            .opacity(showsCloseButton ? 0.7 : 0)
            .allowsHitTesting(showsCloseButton)
            .accessibilityLabel("Close \(tab.title)")
    }

    var body: some View {
        if let tab {
            row(tab)
        }
    }

    private func row(_ tab: BrowserTab) -> some View {
        ZStack(alignment: .trailing) {
            // The padding and the shape live inside the label so the whole row is the button,
            // not just the favicon and the title.
            Button { if !isActivationSuppressed() { store.select(tabID) } } label: {
                rowContent(tab)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The speaker keeps its slot whether or not the close button is showing, so it
            // never slides sideways under the pointer as the row is hovered.
            HStack(spacing: 6) {
                speakerButton
                closeButton(tab)
            }
            .padding(.trailing, 10)
            .animation(.easeOut(duration: 0.14), value: showsSpeaker)
            .animation(.easeOut(duration: 0.12), value: isMuted)
        }
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
        .sidebarDropTarget(.tab(tabID))
        .sidebarDragGesture(payload: .tab(tabID), source: .tab(tabID), began: beginDrag, changed: dragChanged, ended: finishDrag)
        .opacity(store.isClosingTab(tabID) ? 0 : (isDragging ? 0.42 : 1))
        .scaleEffect(store.isClosingTab(tabID) ? 0.82 : (isDragging ? 0.98 : 1), anchor: .trailing)
        .blur(radius: store.isClosingTab(tabID) ? 3 : 0)
        .offset(x: store.isClosingTab(tabID) ? 14 : 0)
        .animation(.easeIn(duration: 0.16), value: store.isClosingTab(tabID))
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
            Button(tab.isPinned ? "Unpin tab" : "Pin tab") { store.togglePinned(tabID) }
            Button(isMuted ? "Unmute tab" : "Mute tab") { store.toggleMuted(tabID) }
            TabBookmarkFolderMenu(store: store, tabID: tabID)
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

struct QuickAccessIconTarget: Identifiable {
    let bookmarkID: UUID
    let folderID: UUID

    var id: UUID { bookmarkID }
}

/// ponytail: a fixed shortlist of SF Symbols rather than a searchable catalogue browser.
/// Swap it for a search field the day the shortlist runs out.
private struct QuickAccessIconPicker: View {
    let selection: String?
    let choose: (String?) -> Void

    private static let symbols = [
        "globe", "magnifyingglass", "star.fill", "heart.fill", "bolt.fill", "flame.fill",
        "leaf.fill", "bookmark.fill", "folder.fill", "tray.full.fill", "envelope.fill", "bell.fill",
        "calendar", "clock.fill", "checklist", "chart.bar.fill", "creditcard.fill", "cart.fill",
        "briefcase.fill", "building.2.fill", "house.fill", "person.crop.circle", "person.2.fill", "bubble.left.fill",
        "chevron.left.forwardslash.chevron.right", "terminal.fill", "hammer.fill", "wrench.and.screwdriver.fill", "cube.fill", "server.rack",
        "apple.logo", "play.rectangle.fill", "music.note", "camera.fill", "photo.fill", "book.fill",
        "map.fill", "airplane", "gamecontroller.fill", "paintbrush.fill", "sparkles", "lock.fill"
    ]

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUICK ACCESS ICON")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { choose(symbol) } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(selection == symbol ? AnyShapeStyle(Color.green) : AnyShapeStyle(.primary))
                            .frame(width: 30, height: 30)
                            .background(
                                selection == symbol ? Color.green.opacity(0.18) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel(symbol)
                }
            }
            Divider()
            Button("Use the site icon") { choose(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(selection == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .disabled(selection == nil)
                .pointerCursor()
        }
        .padding(12)
        .frame(width: 228)
    }
}

private struct TabFavicon: View {
    let address: URL
    let isSuspended: Bool
    let isPinned: Bool
    let fallbackSymbol: String
    /// A symbol the user chose. It replaces the favicon rather than standing in for it.
    let customSymbol: String?

    init(address: URL, isSuspended: Bool, isPinned: Bool, fallbackSymbol: String = "globe", customSymbol: String? = nil) {
        self.address = address
        self.isSuspended = isSuspended
        self.isPinned = isPinned
        self.fallbackSymbol = fallbackSymbol
        self.customSymbol = customSymbol
    }

    var body: some View {
        if let customSymbol {
            Image(systemName: customSymbol).foregroundStyle(.secondary)
        } else if BrowserAddress.isNativeNewTab(address) {
            Image(systemName: "leaf.fill").foregroundStyle(.green)
        } else if isSuspended {
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
        guard !BrowserAddress.isNativeNewTab(address) else { return nil }
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
        // A cursor rect survives the mouse-moved events that undo `NSCursor.set()`, and it
        // stops a control's hover exit from stomping a neighbour's cursor.
        content.pointerStyle(.link)
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

private struct NavigationFailureView: View {
    let failure: NavigationFailure
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: failure.symbol)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.green)
                .padding(22)
                .background(Color.green.opacity(0.12), in: Circle())
                .symbolEffect(.pulse, isActive: isRetrying)

            VStack(spacing: 8) {
                Text(failure.title)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(failure.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Text(failure.address.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(maxWidth: 420)

            // ⌘R reaches the same call through the View menu, so the badge is a reminder
            // rather than a second binding to keep in step.
            Button(action: retry) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(isRetrying ? "Reloading" : "Try again")
                    Text("\u{2318}R")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isRetrying)
            .keyboardShortcut(.defaultAction)
            .pointerCursor()
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(failure.title). \(failure.message)")
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

            // Quick Access can add nine more rows, so the list scrolls instead of growing the
            // sheet past the window.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

            if !store.quickAccessBookmarks.isEmpty {
                paletteSection("QUICK ACCESS") {
                    ForEach(Array(store.quickAccessBookmarks.prefix(9).enumerated()), id: \.element.id) { index, bookmark in
                        command(bookmark.title, symbol: bookmark.customSymbol ?? bookmark.symbol, shortcut: "⌘\(index + 1)") {
                            store.openQuickAccessBookmark(bookmark)
                        }
                    }
                }
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
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 520)
        .frame(maxHeight: 560)
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
