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
        guard let tab = store.selectedTab, !tab.isSuspended,
              let profile = store.profiles.first(where: { $0.id == tab.profileID })
        else { return nil }

        let isDark = colorScheme == .dark
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
        container.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        container.layer?.backgroundColor = WebViewPool.contentBackground(isDark: colorScheme == .dark).cgColor
    }

    /// Keeps every parked tab at the container's size, whoever is on top.
    private final class WebContainerView: NSView {
        override func layout() {
            super.layout()
            subviews.forEach { $0.frame = bounds }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let store: BrowserStore
        private var loadingObservations: [UUID: NSKeyValueObservation] = [:]
        private var observedWebViewIDs: [UUID: ObjectIdentifier] = [:]
        private var downloadIDs: [ObjectIdentifier: UUID] = [:]

        init(store: BrowserStore) {
            self.store = store
        }

        func attach(to webView: WKWebView, tabID: UUID) {
            if webView.navigationDelegate !== self { webView.navigationDelegate = self }
            guard observedWebViewIDs[tabID] != ObjectIdentifier(webView) else { return }
            observedWebViewIDs[tabID] = ObjectIdentifier(webView)
            loadingObservations[tabID] = webView.observe(\WKWebView.isLoading, options: [.initial, .new]) { [weak self] webView, change in
                let isLoading = change.newValue ?? webView.isLoading
                Task { @MainActor [weak self] in
                    self?.store.setNavigationLoading(isLoading, for: tabID)
                }
            }
        }

        /// Delegate callbacks arrive for every tab this coordinator serves, so the tab is
        /// resolved from the web view rather than from whichever tab is on screen.
        private func tabID(of webView: WKWebView) -> UUID? { WebViewPool.shared.tabID(for: webView) }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let tabID = tabID(of: webView) else { return }
            store.didCommitNavigation(for: tabID, url: webView.url)
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
            guard let destination = BrowserStore.commandClickDestination(
                navigationType: navigationAction.navigationType,
                modifierFlags: navigationAction.modifierFlags,
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                requestURL: navigationAction.request.url
            ) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard let tabID = tabID(of: webView) else { return }
            store.openLinkInNewTab(destination, from: tabID)
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
            store.didFailNavigation(for: tabID)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let tabID = tabID(of: webView) else { return }
            store.didFailNavigation(for: tabID)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let tabID = tabID(of: webView) else { return }
            store.didTerminateWebContent(for: tabID)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            configure(download: download, sourceAddress: navigationAction.request.url ?? webView.url, tabID: tabID(of: webView))
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            configure(download: download, sourceAddress: navigationResponse.response.url ?? webView.url, tabID: tabID(of: webView))
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
            guard let downloadID = downloadIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
            store.finishDownload(downloadID)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard let downloadID = downloadIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
            store.failDownload(downloadID, errorDescription: error.localizedDescription)
        }

        private func configure(download: WKDownload, sourceAddress: URL?, tabID: UUID?) {
            guard let tabID = tabID ?? store.selectedTabID else { return }
            let sourceAddress = sourceAddress ?? BrowserAddress.home
            let downloadID = store.beginDownload(for: tabID, sourceAddress: sourceAddress)
            downloadIDs[ObjectIdentifier(download)] = downloadID
            download.delegate = self
        }
    }
}
