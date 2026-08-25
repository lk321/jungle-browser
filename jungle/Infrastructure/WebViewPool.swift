import AppKit
import WebKit

@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var webViews: [UUID: WKWebView] = [:]
    private var hostViews: [UUID: NSView] = [:]

    private init() {}

    func webView(for tab: BrowserTab, profile: BrowserProfile) -> WKWebView {
        if let webView = webViews[tab.id] { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.dataStoreID)
        configuration.preferences.isElementFullscreenEnabled = true
        // ponytail: WKWebView keeps Picture in Picture and the programmatic Web Inspector
        // switched off, and neither has a public setter. These two keys are the whole difference.
        configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.addUserScript(Self.mediaScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webViews[tab.id] = webView
        return webView
    }

    /// The view a tab keeps for as long as it lives. WebKit docks the Web Inspector beside
    /// the web view inside its superview, so that superview has to outlive the container
    /// SwiftUI rebuilds on every tab switch — otherwise the docked inspector is left behind
    /// in the discarded container and the page keeps the shrunken frame it had.
    func hostView(for tab: BrowserTab, profile: BrowserProfile) -> NSView {
        if let hostView = hostViews[tab.id] { return hostView }

        let webView = webView(for: tab, profile: profile)
        let hostView = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = hostView.bounds
        webView.autoresizingMask = [.width, .height]
        hostView.addSubview(webView)
        hostViews[tab.id] = hostView
        return hostView
    }

    func contains(_ tabID: UUID) -> Bool { webViews[tabID] != nil }

    func takeSnapshot(of tabID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let webView = webViews[tabID] else { completion(nil); return }
        webView.takeSnapshot(with: nil) { image, _ in completion(image) }
    }

    func enterPictureInPicture(for tabID: UUID) {
        evaluate("__jungleMedia.enterPictureInPicture()", in: tabID)
    }

    func togglePictureInPicture(for tabID: UUID) {
        evaluate("__jungleMedia.togglePictureInPicture()", in: tabID)
    }

    /// Reports whether the tab still plays media or holds a Picture in Picture window,
    /// so idle housekeeping leaves its web process alone.
    func holdsPlayback(_ tabID: UUID, completion: @escaping (Bool) -> Void) {
        guard let webView = webViews[tabID] else { completion(false); return }
        webView.evaluateJavaScript("__jungleMedia.holdsPlayback()", in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): completion((value as? Bool) ?? false)
            case .failure: completion(false)
            }
        }
    }

    func discard(_ tabID: UUID) {
        guard let webView = webViews.removeValue(forKey: tabID) else { return }
        webView.stopLoading()
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        hostViews.removeValue(forKey: tabID)?.removeFromSuperview()
    }

    private func evaluate(_ script: String, in tabID: UUID) {
        guard let webView = webViews[tabID] else { return }
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    /// Tracks the video the page is playing and exposes the presentation-mode calls the
    /// app drives from AppKit. Lives in the client content world so pages cannot see it.
    ///
    /// ponytail: main frame only, which covers YouTube and every site that plays in the
    /// page itself. Videos inside a cross-origin iframe need per-frame evaluation; add it
    /// when a site that matters actually needs it.
    private static let mediaScript = WKUserScript(
        source: """
        (function () {
            let activeVideo = null;

            document.addEventListener('play', function (event) {
                if (event.target instanceof HTMLVideoElement) { activeVideo = event.target; }
            }, true);

            document.addEventListener('pause', function (event) {
                // Pausing while the page is on screen is the user's call; hiding the page
                // pauses playback on our behalf and must not clear the active video.
                if (event.target === activeVideo && document.visibilityState === 'visible') {
                    activeVideo = null;
                }
            }, true);

            function playingVideo() {
                if (!activeVideo || !activeVideo.isConnected || activeVideo.ended) { return null; }
                if (typeof activeVideo.webkitSetPresentationMode !== 'function') { return null; }
                if (!activeVideo.webkitSupportsPresentationMode('picture-in-picture')) { return null; }
                return activeVideo;
            }

            function pictureInPictureVideo() {
                return Array.prototype.find.call(
                    document.querySelectorAll('video'),
                    function (video) { return video.webkitPresentationMode === 'picture-in-picture'; }
                ) || null;
            }

            window.__jungleMedia = {
                enterPictureInPicture: function () {
                    const video = playingVideo();
                    if (!video || video.webkitPresentationMode === 'picture-in-picture') { return false; }
                    video.webkitSetPresentationMode('picture-in-picture');
                    return true;
                },
                exitPictureInPicture: function () {
                    const video = pictureInPictureVideo();
                    if (!video) { return false; }
                    video.webkitSetPresentationMode('inline');
                    return true;
                },
                togglePictureInPicture: function () {
                    if (this.exitPictureInPicture()) { return true; }
                    const video = playingVideo() || document.querySelector('video');
                    if (!video || typeof video.webkitSetPresentationMode !== 'function') { return false; }
                    if (!video.webkitSupportsPresentationMode('picture-in-picture')) { return false; }
                    video.webkitSetPresentationMode('picture-in-picture');
                    return true;
                },
                holdsPlayback: function () {
                    return Array.prototype.some.call(
                        document.querySelectorAll('video, audio'),
                        function (media) {
                            return (!media.paused && !media.ended)
                                || media.webkitPresentationMode === 'picture-in-picture';
                        }
                    );
                }
            };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )
}
