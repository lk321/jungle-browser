import AppKit
import SwiftUI
import WebKit

/// One container for every tab. The host views stay parented to it for as long as their tab
/// lives: WebKit closes the Picture in Picture window the instant the view owning the video
/// leaves the window, so tearing a tab's view out on every switch is what made the floating
/// window flicker away or never appear.
struct BrowserWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: BrowserStore

    private var usesDarkContent: Bool {
        store.settings.appearance.usesDarkContent(systemIsDark: colorScheme == .dark)
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSView {
        let container = WebContainerView()
        container.wantsLayer = true
        applyContentBackground(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        applyContentBackground(to: container)
        let visibleHostView = attachSelectedTab(to: container, coordinator: context.coordinator)
        let holdHostView = store.pictureInPictureHoldTabID.flatMap { WebViewPool.shared.attachedHostView(for: $0) }
        for hostView in container.subviews {
            let isVisible = hostView === visibleHostView
            // The tab holding the floating window stays in the window, just out of sight. WebKit's
            // own answer counts too, so a window the store has not heard about yet is never
            // hidden into a page that says "playing in Picture in Picture" with nothing on screen.
            hostView.isHidden = !isVisible && hostView !== holdHostView
                && !WebViewPool.shared.hostsPictureInPicture(hostView)
            hostView.alphaValue = isVisible ? 1 : 0
        }
        store.loadSelectedTabIfNeeded()
    }

    private func attachSelectedTab(to container: NSView, coordinator: Coordinator) -> NSView? {
        guard let tab = store.selectedTab, !tab.isSuspended, !tab.isNativeNewTab,
              let profile = store.profiles.first(where: { $0.id == tab.profileID })
        else { return nil }

        let isDark = usesDarkContent
        let webView = WebViewPool.shared.webView(for: tab, profile: profile, isDark: isDark)
        WebViewPool.shared.applyContentBackground(isDark: isDark, to: webView)
        coordinator.attach(to: webView, tabID: tab.id)

        let hostView = WebViewPool.shared.hostView(for: tab, profile: profile, isDark: isDark)
        guard container.subviews.last !== hostView else { return hostView }
        // The container lays its subviews out itself, so bringing the selected tab to the front
        // is a plain re-add — constraints would not survive the move.
        hostView.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(hostView, positioned: .above, relativeTo: nil)
        container.needsLayout = true
        return hostView
    }

    private func applyContentBackground(to container: NSView) {
        container.appearance = NSAppearance(named: usesDarkContent ? .darkAqua : .aqua)
        container.layer?.backgroundColor = WebViewPool.contentBackground(isDark: usesDarkContent).cgColor
    }

    /// Keeps every parked tab at the container's size, whoever is on top.
    private final class WebContainerView: NSView {
        override func layout() {
            super.layout()
            subviews.forEach { $0.frame = bounds }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, ContextMenuDownloadStarter {
        let store: BrowserStore
        /// Whether a prompt to open another app is on screen. Asks that arrive meanwhile are
        /// dropped, not queued: a page firing the same app link in a loop would otherwise
        /// stack one alert behind another.
        private var isAskingToOpenApp: Bool = false

        init(store: BrowserStore) {
            self.store = store
        }

        func attach(to webView: WKWebView, tabID: UUID) {
            if webView.navigationDelegate !== self { webView.navigationDelegate = self }
            if webView.uiDelegate !== self { webView.uiDelegate = self }
            (webView as? JungleWebView)?.downloadStarter = self
            if let webView = webView as? JungleWebView {
                webView.sidebarShortcutIsArmed = { [weak store] in store?.isSidebarShortcutHintVisible == true }
                webView.sidebarShortcutReachedPage = { [weak store] pressedAt in
                    store?.sidebarShortcutReachedPage(in: tabID, pressedAt: pressedAt)
                }
            }
            // The observations are kept on the view, so a view that has them is already
            // observed, and they go away with it when its tab closes or sleeps.
            guard let webView = webView as? JungleWebView, webView.observations.isEmpty else { return }
            // The store, not the coordinator: the observations outlive this coordinator when
            // SwiftUI builds a new one, and the check above never observes the view again.
            let store: BrowserStore = store
            let loading: NSKeyValueObservation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak store] webView, change in
                let isLoading = change.newValue ?? webView.isLoading
                Task { @MainActor [weak store] in
                    store?.setNavigationLoading(isLoading, for: tabID)
                }
            }
            // `didCommit` never fires for a same-document navigation, which is how YouTube and
            // every other pushState app moves between pages. Observing the property covers
            // both kinds of navigation with one mechanism.
            let address: NSKeyValueObservation = webView.observe(\.url, options: [.new]) { [weak store] webView, _ in
                let url = webView.url
                Task { @MainActor [weak store] in
                    store?.didCommitNavigation(for: tabID, url: url)
                }
            }
            webView.observations = [loading, address]
        }

        /// Delegate callbacks arrive for every tab this coordinator serves, so the tab is
        /// resolved from the web view rather than from whichever tab is on screen.
        private func tabID(of webView: WKWebView) -> UUID? { WebViewPool.shared.tabID(for: webView) }

        /// WebKit's private UI delegate call, the one Safari tracks Picture in Picture with. It
        /// fires for every frame and shadow root, whichever control started or ended it.
        @objc(_webView:hasVideoInPictureInPictureDidChange:)
        func webView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange isActive: Bool) {
            guard let tabID = tabID(of: webView) else { return }
            WebViewPool.shared.pictureInPictureDidChange(isActive: isActive, tabID: tabID)
            store.pictureInPictureDidChange(isActive: isActive, tabID: tabID)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let tabID = tabID(of: webView) else { return }
            store.didCommitNavigation(for: tabID, url: webView.url)
        }

        /// Camera and microphone. Without this the request never reaches anyone and WebKit
        /// leaves the page waiting, which is what made every video call arrive mute and blind.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let kinds: [SitePermissions.Kind] = switch type {
            case .camera: [.camera]
            case .microphone: [.microphone]
            default: [.camera, .microphone]
            }
            let origin = SitePermissions.describe(origin)
            Task { @MainActor in
                let allowed = await SitePermissions.request(kinds, origin: origin, in: webView.window)
                decisionHandler(allowed ? .grant : .deny)
            }
        }

        /// Screen sharing. `getDisplayMedia` is only offered over this private delegate method,
        /// and the decision tells WebKit which of its own pickers to put up.
        ///
        /// ponytail: the answer is never remembered, same as in Chrome and Safari — sharing a
        /// screen is the one permission worth asking for every single time.
        @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
        func requestDisplayCapturePermission(
            _ webView: WKWebView,
            origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            withSystemAudio: Bool,
            decisionHandler: @escaping (Int) -> Void
        ) {
            let origin = SitePermissions.describe(origin)
            Task { @MainActor in
                let choice = await SitePermissions.ask(
                    "\u{201C}\(origin)\u{201D} wants to share your screen.",
                    information: "You pick the screen or the window to share next.",
                    buttons: ["Share Screen", "Share a Window", "Cancel"],
                    in: webView.window
                )
                // WKDisplayCapturePermissionDecision: deny, prompt for a screen, prompt for a window.
                let decisions = [1, 2, 0]
                decisionHandler(decisions.indices.contains(choice) ? decisions[choice] : 0)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let tabID = tabID(of: webView) else { return }
            store.didStartNavigation(for: tabID)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let tabID = tabID(of: webView) else { return }
            store.didFinishNavigation(for: tabID, title: webView.title, url: webView.url)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // A link carrying `download` is answered by downloading it. Allowing the
            // navigation instead sent the tab to the file itself, which is what left the tab
            // blank on a page that offered an image for download. The `.download` policy is
            // the documented answer and this WebKit answered it with nothing at all: no
            // delegate call and no request, measured on macOS 26. The request is made the same
            // way the context menu makes one.
            //
            // ponytail: only `http(s)`. `startDownload` issues a fresh request, which a
            // `blob:` URL has no origin to serve, so a blob link keeps the old behaviour of
            // opening in the tab rather than downloading nothing at all.
            if navigationAction.shouldPerformDownload,
               let address = navigationAction.request.url,
               BrowserAddress.isWebURL(address) {
                decisionHandler(.cancel)
                startDownload(from: address, in: webView)
                return
            }
            // A link asking for a new window arrives here with no target frame, ahead of the
            // window itself; it is answered where the window is asked for, so it is asked once.
            if let address = navigationAction.request.url,
               BrowserAddress.opensInAnotherApp(address),
               let targetFrame = navigationAction.targetFrame {
                decisionHandler(.cancel)
                guard Self.mayOpenAnotherApp(navigationAction, in: webView) else { return }
                askToOpenInAnotherApp(address, from: webView)
                // A tab opened only to bounce to the app never gets a document; same cleanup
                // as a tab opened only to carry a download.
                if targetFrame.isMainFrame, webView.backForwardList.currentItem == nil, let tabID = tabID(of: webView) {
                    store.closeTabOpenedForDownload(tabID)
                }
                return
            }
            guard let destination = BrowserStore.commandClickDestination(
                navigationType: navigationAction.navigationType,
                modifierFlags: navigationAction.modifierFlags,
                requestURL: navigationAction.request.url
            ) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard let tabID = tabID(of: webView) else { return }
            store.openLinkInNewTab(destination, from: tabID)
        }

        /// A `target="_blank"` link or a `window.open` lands in a tab carrying the web view
        /// WebKit asked for. Opening a tab of our own and answering `nil` instead told the page
        /// its popup had been blocked, and a page that hears that runs its fallback: the file
        /// a Jira attachment button opens was fetched once by the tab and once more by the
        /// fallback, which is what downloaded everything twice.
        ///
        /// ponytail: a popup opened at `about:blank` for the page to write into is still
        /// dropped. Serving one means a tab with no address to show; add it if a site that
        /// matters actually needs it.
        ///
        /// A window a script asked for is also spaced out from the last one the same tab
        /// opened. WebKit already refuses windows with no user gesture behind them; what it
        /// does not bound is the burst of `window.open` calls a single click can carry, which
        /// is how an ad page puts five windows on screen at once.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // An app link never gets a tab: it would stay blank once the app took the address.
            // It is settled before the popup checks so it does not spend the tab's popup budget.
            if let address = navigationAction.request.url, BrowserAddress.opensInAnotherApp(address) {
                if Self.mayOpenAnotherApp(navigationAction, in: webView) {
                    askToOpenInAnotherApp(address, from: webView)
                }
                return nil
            }
            guard let destination = BrowserStore.newWindowDestination(
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                requestURL: navigationAction.request.url
            ), let tabID = tabID(of: webView),
                  store.allowsPopup(
                      from: tabID,
                      isFromEmbeddedOtherSiteFrame: Self.isEmbeddedOtherSiteFrame(navigationAction.sourceFrame, in: webView)
                          && !BrowserStore.isAccountProviderWindow(
                              frameHost: navigationAction.sourceFrame.securityOrigin.host,
                              destinationHost: destination.host
                          ),
                      isLinkActivated: navigationAction.navigationType == .linkActivated
                  ),
                  let popupTabID = store.openPopupTab(from: tabID, address: destination)
            else { return nil }
            let popup = WebViewPool.shared.adoptPopup(configuration: configuration, for: popupTabID)
            attach(to: popup, tabID: popupTabID)
            return popup
        }

        /// Whether the page, and not an ad embedded in it, is reaching for another app. What
        /// counts is the frame that asked: Zoom's launcher, like many, loads the app link into a
        /// hidden frame of its own, so judging by the frame being navigated dropped every one of
        /// them without a word. A frame from another site reaching for an app unclicked is an ad.
        private static func mayOpenAnotherApp(_ navigationAction: WKNavigationAction, in webView: WKWebView) -> Bool {
            navigationAction.navigationType == .linkActivated
                || !isEmbeddedOtherSiteFrame(navigationAction.sourceFrame, in: webView)
        }

        /// Whether the window was asked for by a frame embedded from another site, rather than
        /// by the page the tab is showing.
        private static func isEmbeddedOtherSiteFrame(_ frame: WKFrameInfo, in webView: WKWebView) -> Bool {
            guard !frame.isMainFrame else { return false }
            return !BrowserStore.isSameSite(frameHost: frame.securityOrigin.host, pageHost: webView.url?.host)
        }

        /// Hands an address WebKit cannot load to the app registered for it, once the user
        /// allows it — the "Open App" button a sign-in page shows did nothing at all before.
        /// Nothing is asked when no app on this Mac takes the scheme: there is nothing to allow.
        private func askToOpenInAnotherApp(_ address: URL, from webView: WKWebView) {
            guard !isAskingToOpenApp,
                  let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: address)
            else { return }
            isAskingToOpenApp = true
            // `displayName` keeps the extension when Finder is set to show them all.
            let fileName: String = FileManager.default.displayName(atPath: applicationURL.path)
            let appName: String = fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
            let site: String = SitePermissions.describe(webView.url) ?? "This page"
            let window: NSWindow? = webView.window
            Task { @MainActor [weak self] in
                let choice = await SitePermissions.ask(
                    "Do you want to allow this website to open \u{201C}\(appName)\u{201D}?",
                    information: "\(site) wants to open a link in another app.",
                    buttons: ["Allow", "Cancel"],
                    in: window
                )
                self?.isAskingToOpenApp = false
                guard choice == 0 else { return }
                NSWorkspace.shared.open(address)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let isAttachment = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?
                .localizedCaseInsensitiveContains("attachment") == true
            // A disk image or an archive served without `attachment` is still a file: allowed as
            // a page, WebKit has nothing to show and the navigation fails. Only the main frame's,
            // so an embedded ad serving a binary never becomes a download.
            let isUnshowableFile = navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType
            decisionHandler(isAttachment || isUnshowableFile ? .download : .allow)
        }

        /// A page's `window.close()`: a sign-in window closes itself once it has signed the
        /// opener in, and the user lands back on the page that opened it.
        func webViewDidClose(_ webView: WKWebView) {
            guard let tabID = tabID(of: webView) else { return }
            store.closePopupTab(tabID)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard let tabID = tabID(of: webView) else { return }
            store.didFailNavigation(for: tabID, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let tabID = tabID(of: webView) else { return }
            store.didFailNavigation(for: tabID, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let tabID = tabID(of: webView) else { return }
            store.didTerminateWebContent(for: tabID)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            configure(download: download, sourceAddress: navigationAction.request.url ?? webView.url, tabID: tabID(of: webView))
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            let tabID = tabID(of: webView)
            configure(download: download, sourceAddress: navigationResponse.response.url ?? webView.url, tabID: tabID)
            // A tab a link opened only to download something never receives a document: WebKit
            // hands the response to the downloader and leaves the tab blank forever. The
            // back-forward list is what says so — `url` still holds the provisional address
            // while the response is being handed over, which left the blank tab on screen.
            guard let tabID, webView.backForwardList.currentItem == nil, !webView.canGoBack else { return }
            store.closeTabOpenedForDownload(tabID)
        }

        /// WebKit's own context-menu download never reaches the app, so the menu item hands
        /// the address back here and the download is started over public API instead.
        func startDownload(from address: URL, in webView: WKWebView) {
            let tabID = tabID(of: webView)
            webView.startDownload(using: URLRequest(url: address)) { [weak self] download in
                self?.configure(download: download, sourceAddress: address, tabID: tabID)
            }
        }

        private func configure(download: WKDownload, sourceAddress: URL?, tabID: UUID?) {
            guard let tabID = tabID ?? store.selectedTabID else { return }
            FileDownloads.shared.track(download, store: store, tabID: tabID, sourceAddress: sourceAddress ?? BrowserAddress.home)
        }
    }
}
