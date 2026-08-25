import Foundation
import WebKit

/// Drives the WebKit Web Inspector that Safari and Orion ship, which WebKit exposes
/// to embedders only through `-[WKWebView _inspector]`.
///
/// ponytail: SPI is the only programmatic path; every call is guarded and degrades to
/// a no-op. Right-click "Inspect Element" needs nothing but `isInspectable`. Shipping
/// this rules out Mac App Store distribution.
@MainActor
enum WebInspector {
    static func toggle(for webView: WKWebView) {
        guard let inspector = inspector(for: webView) else { return }
        if isVisible(inspector) {
            send("hide", to: inspector)
        } else {
            show(inspector)
        }
    }

    static func showConsole(for webView: WKWebView) {
        guard let inspector = inspector(for: webView) else { return }
        show(inspector)
        send("showConsole", to: inspector)
    }

    private static func show(_ inspector: NSObject) {
        if !flag("connected", on: inspector) { send("connect", to: inspector) }
        send("show", to: inspector)
    }

    private static func isVisible(_ inspector: NSObject) -> Bool { flag("visible", on: inspector) }

    private static func inspector(for webView: WKWebView) -> NSObject? {
        let selector = Selector(("_inspector"))
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func flag(_ key: String, on inspector: NSObject) -> Bool {
        inspector.value(forKey: key) as? Bool ?? false
    }

    private static func send(_ message: String, to inspector: NSObject) {
        let selector = Selector((message))
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }
}
