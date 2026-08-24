import AppKit
import WebKit

@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var webViews: [UUID: WKWebView] = [:]

    private init() {}

    func webView(for tab: BrowserTab, profile: BrowserProfile) -> WKWebView {
        if let webView = webViews[tab.id] { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.dataStoreID)
        configuration.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webViews[tab.id] = webView
        return webView
    }

    func contains(_ tabID: UUID) -> Bool { webViews[tabID] != nil }

    func takeSnapshot(of tabID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let webView = webViews[tabID] else { completion(nil); return }
        webView.takeSnapshot(with: nil) { image, _ in completion(image) }
    }

    func discard(_ tabID: UUID) {
        guard let webView = webViews.removeValue(forKey: tabID) else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}
