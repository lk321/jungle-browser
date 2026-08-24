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
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: BrowserStore
        var tabID: UUID

        init(store: BrowserStore, tabID: UUID) {
            self.store = store
            self.tabID = tabID
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
    }
}
