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
    /// The loading and address observations the browser keeps on this view. They live here so
    /// they end with the view: kept anywhere else, they outlived every closed or slept tab.
    var observations: [NSKeyValueObservation] = []
    /// What the pointer was over when the page last raised a context menu, by menu item.
    fileprivate var contextMenuDownloads: [String: URL] = [:]
    /// Whether ⌘B should skip the page and go straight to the sidebar: true right after the
    /// page kept one for itself and the browser offered the second press.
    var sidebarShortcutIsArmed: () -> Bool = { false }
    /// Called once WebKit has heard back from the page about a ⌘B, with when it was pressed.
    /// The key never reaching the menu by then means the page kept it.
    var sidebarShortcutReachedPage: (Date) -> Void = { _ in }
    /// The ⌘B the page has but has not answered for yet.
    private var pendingSidebarShortcut: NSEvent?

    /// ⌘B toggles the sidebar, and editors use it for bold. WebKit hands the key to the page
    /// first and only sends it on to the menu if the page leaves it alone, so on a page that
    /// takes it the sidebar never heard of the press. The browser then offers the second press,
    /// which bypasses the page.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "b", !event.isARepeat
        else { return super.performKeyEquivalent(with: event) }
        // The same event coming back is WebKit sending it on to the menu: the page left it alone.
        if event === pendingSidebarShortcut {
            pendingSidebarShortcut = nil
            return super.performKeyEquivalent(with: event)
        }
        if sidebarShortcutIsArmed() {
            NotificationCenter.default.post(name: .jungleToggleSidebar, object: nil)
            return true
        }
        // False: the page is not in focus, so the menu has it already.
        guard super.performKeyEquivalent(with: event) else { return false }
        let pressedAt = Date.now
        // ponytail: WebKit's private hook, the one that runs once the page has answered for every
        // key sent so far. Without it there is no hint, and ⌘B behaves exactly as it did before.
        let afterPendingKeys = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
        guard responds(to: afterPendingKeys) else { return true }
        pendingSidebarShortcut = event
        let reached: @convention(block) () -> Void = { [weak self] in
            guard let self, self.pendingSidebarShortcut === event else { return }
            self.pendingSidebarShortcut = nil
            self.sidebarShortcutReachedPage(pressedAt)
        }
        perform(afterPendingKeys, with: reached as AnyObject)
        return true
    }

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
