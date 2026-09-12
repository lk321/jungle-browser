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
            // The tab holding the floating window stays in the window, just out of sight.
            hostView.isHidden = !isVisible && hostView !== holdHostView
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, ContextMenuDownloadStarter {
        let store: BrowserStore
        private var loadingObservations: [UUID: NSKeyValueObservation] = [:]
        private var addressObservations: [UUID: NSKeyValueObservation] = [:]
        private var observedWebViewIDs: [UUID: ObjectIdentifier] = [:]
        private var downloadIDs: [ObjectIdentifier: UUID] = [:]
        private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]

        init(store: BrowserStore) {
            self.store = store
        }

        func attach(to webView: WKWebView, tabID: UUID) {
            if webView.navigationDelegate !== self { webView.navigationDelegate = self }
            if webView.uiDelegate !== self { webView.uiDelegate = self }
            (webView as? JungleWebView)?.downloadStarter = self
            guard observedWebViewIDs[tabID] != ObjectIdentifier(webView) else { return }
            observedWebViewIDs[tabID] = ObjectIdentifier(webView)
            loadingObservations[tabID] = webView.observe(\WKWebView.isLoading, options: [.initial, .new]) { [weak self] webView, change in
                let isLoading = change.newValue ?? webView.isLoading
                Task { @MainActor [weak self] in
                    self?.store.setNavigationLoading(isLoading, for: tabID)
                }
            }
            // `didCommit` never fires for a same-document navigation, which is how YouTube and
            // every other pushState app moves between pages. Observing the property covers
            // both kinds of navigation with one mechanism.
            addressObservations[tabID] = webView.observe(\WKWebView.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url
                Task { @MainActor [weak self] in
                    self?.store.didCommitNavigation(for: tabID, url: url)
                }
            }
        }

        /// Delegate callbacks arrive for every tab this coordinator serves, so the tab is
        /// resolved from the web view rather than from whichever tab is on screen.
        private func tabID(of webView: WKWebView) -> UUID? { WebViewPool.shared.tabID(for: webView) }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            WebNotifications.shared.seedPermission(in: webView)
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
        ///
        /// Known gap: WebKit answers `respondsToSelector:` for this method and the
        /// `screenCaptureEnabled` preference is on, yet a sandboxed build never sees the call —
        /// `getDisplayMedia` stalls inside the web process with no permission request, no
        /// prompt and no rejection. Camera and microphone go through the public delegate on the
        /// same build. Next step is a throwaway unsandboxed build to confirm the App Sandbox is
        /// what swallows it.
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
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let destination = BrowserStore.newWindowDestination(
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                requestURL: navigationAction.request.url
            ), let tabID = tabID(of: webView),
                  let popupTabID = store.openPopupTab(from: tabID, address: destination)
            else { return nil }
            let popup = WebViewPool.shared.adoptPopup(configuration: configuration, for: popupTabID)
            attach(to: popup, tabID: popupTabID)
            return popup
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  response.value(forHTTPHeaderField: "Content-Disposition")?.localizedCaseInsensitiveContains("attachment") == true
            else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.download)
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

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            guard let downloadID = downloadIDs[ObjectIdentifier(download)] else {
                completionHandler(nil)
                return
            }
            completionHandler(
                store.prepareDownloadDestination(
                    for: downloadID,
                    suggestedFileName: suggestedFilename,
                    expectedBytes: response.expectedContentLength
                )
            )
        }

        func download(_ download: WKDownload, didReceiveDataOfLength length: Int) {
            guard let downloadID = downloadIDs[ObjectIdentifier(download)] else { return }
            store.recordDownloadData(Int64(length), for: downloadID)
        }

        func downloadDidFinish(_ download: WKDownload) {
            activeDownloads.removeValue(forKey: ObjectIdentifier(download))
            guard let downloadID = downloadIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
            store.finishDownload(downloadID)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            activeDownloads.removeValue(forKey: ObjectIdentifier(download))
            guard let downloadID = downloadIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
            store.failDownload(downloadID, errorDescription: error.localizedDescription)
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
            let sourceAddress = sourceAddress ?? BrowserAddress.home
            let downloadID = store.beginDownload(for: tabID, sourceAddress: sourceAddress)
            downloadIDs[ObjectIdentifier(download)] = downloadID
            // `WKDownload` holds its delegate and its web view weakly and nothing else keeps it
            // alive, so closing the tab it came from would otherwise cancel the transfer.
            activeDownloads[ObjectIdentifier(download)] = download
            download.delegate = self
        }
    }
}
