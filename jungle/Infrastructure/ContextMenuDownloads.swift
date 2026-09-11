import AppKit
import WebKit

/// Starts a download WebKit itself would not: the ones its context menu drops, and the ones
/// a `download` link asks for.
@MainActor
protocol ContextMenuDownloadStarter: AnyObject {
    func startDownload(from address: URL, in webView: WKWebView)
}

/// WebKit's "Download Image" and "Download Linked File" go straight to a `WKDownload` the
/// app never sees: the public API hands one over for navigations only, so nothing sets a
/// delegate, nothing picks a destination, and WebKit gives up with
/// "Could not create a sandbox extension for ''". The menu items are re-pointed at the app,
/// which runs the same download through `startDownload(using:)` and keeps the delegate.
final class JungleWebView: WKWebView {
    weak var downloadStarter: (any ContextMenuDownloadStarter)?
    /// What the pointer was over when the page last raised a context menu, by menu item.
    fileprivate var contextMenuDownloads: [String: URL] = [:]

    static let downloadItemIdentifiers: Set<String> = [
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierDownloadMedia"
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // The address is read when the item is clicked, not now: the page reports what the
        // pointer is over on the same connection that carries the menu, and only the click is
        // late enough to be sure that message has landed.
        for item in menu.items {
            guard let identifier = item.identifier?.rawValue, Self.downloadItemIdentifiers.contains(identifier) else { continue }
            item.target = self
            item.action = #selector(startContextMenuDownload(_:))
        }
    }

    @objc private func startContextMenuDownload(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue, let address = contextMenuDownloads[identifier] else { return }
        downloadStarter?.startDownload(from: address, in: self)
    }

    static let contextMenuHandlerName = "jungleContextMenu"

    /// Reports the image, link and media under the pointer as the page raises its context
    /// menu. `closest` walks up from the node that was clicked, so an image wrapped in a link
    /// answers for both menu items.
    static let contextMenuScript = WKUserScript(
        source: """
        (function () {
            function nearest(node, selector) {
                return node && node.closest ? node.closest(selector) : null;
            }

            document.addEventListener('contextmenu', function (event) {
                const image = nearest(event.target, 'img');
                const link = nearest(event.target, 'a[href]');
                const media = nearest(event.target, 'video, audio');
                window.webkit.messageHandlers.jungleContextMenu.postMessage({
                    WKMenuItemIdentifierDownloadImage: image ? (image.currentSrc || image.src || '') : '',
                    WKMenuItemIdentifierDownloadLinkedFile: link ? link.href : '',
                    WKMenuItemIdentifierDownloadMedia: media ? (media.currentSrc || media.src || '') : ''
                });
            }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .defaultClient
    )
}

final class ContextMenuMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? JungleWebView, let body = message.body as? [String: Any] else { return }
        webView.contextMenuDownloads = body.compactMapValues { value in
            guard let address = value as? String, let url = URL(string: address), BrowserAddress.isWebURL(url) else { return nil }
            return url
        }
    }
}
