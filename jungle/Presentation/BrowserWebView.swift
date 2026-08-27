import AppKit
import SwiftUI
import WebKit

struct BrowserWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let profile: BrowserProfile

    func makeCoordinator() -> Coordinator { Coordinator(store: store, tabID: tab.id) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        applyContentBackground(to: container)
        attachWebView(to: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.tabID = tab.id
        applyContentBackground(to: container)
        attachWebView(to: container, coordinator: context.coordinator)
        store.loadSelectedTabIfNeeded()
    }

    private func attachWebView(to container: NSView, coordinator: Coordinator) {
        let isDark = colorScheme == .dark
        let webView = WebViewPool.shared.webView(for: tab, profile: profile, isDark: isDark)
        WebViewPool.shared.applyContentBackground(isDark: isDark, to: webView)
        webView.navigationDelegate = coordinator
        coordinator.observeLoading(of: webView)
        let hostView = WebViewPool.shared.hostView(for: tab, profile: profile, isDark: isDark)
        guard hostView.superview !== container else { return }
        hostView.removeFromSuperview()
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func applyContentBackground(to container: NSView) {
        container.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        container.layer?.backgroundColor = WebViewPool.contentBackground(isDark: colorScheme == .dark).cgColor
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let store: BrowserStore
        var tabID: UUID
        private weak var observedWebView: WKWebView?
        private var loadingObservation: NSKeyValueObservation?
        private var downloadIDs: [ObjectIdentifier: UUID] = [:]

        init(store: BrowserStore, tabID: UUID) {
            self.store = store
            self.tabID = tabID
        }

        deinit {
            loadingObservation?.invalidate()
        }

        func observeLoading(of webView: WKWebView) {
            guard observedWebView !== webView else { return }
            loadingObservation?.invalidate()
            observedWebView = webView
            loadingObservation = webView.observe(\WKWebView.isLoading, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.store.setNavigationLoading(webView.isLoading, for: self.tabID)
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            store.didCommitNavigation(for: tabID, url: webView.url)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.didStartNavigation(for: tabID)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
            store.didFailNavigation(for: tabID)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            store.didFailNavigation(for: tabID)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            store.didTerminateWebContent(for: tabID)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            configure(download: download, sourceAddress: navigationAction.request.url ?? webView.url)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            configure(download: download, sourceAddress: navigationResponse.response.url ?? webView.url)
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

        private func configure(download: WKDownload, sourceAddress: URL?) {
            let sourceAddress = sourceAddress ?? BrowserAddress.home
            let downloadID = store.beginDownload(for: tabID, sourceAddress: sourceAddress)
            downloadIDs[ObjectIdentifier(download)] = downloadID
            download.delegate = self
        }
    }
}
