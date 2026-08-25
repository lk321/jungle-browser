import AppKit
import SwiftUI
import WebKit

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let profile: BrowserProfile

    func makeCoordinator() -> Coordinator { Coordinator(store: store, tabID: tab.id) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        attachWebView(to: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.tabID = tab.id
        attachWebView(to: container, coordinator: context.coordinator)
        store.loadSelectedTabIfNeeded()
    }

    private func attachWebView(to container: NSView, coordinator: Coordinator) {
        let webView = WebViewPool.shared.webView(for: tab, profile: profile)
        webView.navigationDelegate = coordinator
        coordinator.observeLoading(of: webView)
        let hostView = WebViewPool.shared.hostView(for: tab, profile: profile)
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: BrowserStore
        var tabID: UUID
        private weak var observedWebView: WKWebView?
        private var loadingObservation: NSKeyValueObservation?

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

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.didFailNavigation(for: tabID)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            store.didFailNavigation(for: tabID)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            store.didFailNavigation(for: tabID)
        }
    }
}
