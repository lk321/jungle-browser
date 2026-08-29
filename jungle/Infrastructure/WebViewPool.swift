import AppKit
import WebKit

@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var webViews: [UUID: WKWebView] = [:]
    private var hostViews: [UUID: NSView] = [:]

    private init() {}

    func webView(for tab: BrowserTab, profile: BrowserProfile, isDark: Bool? = nil) -> WKWebView {
        if let webView = webViews[tab.id] {
            if let isDark { applyContentBackground(isDark: isDark, to: webView) }
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.dataStoreID)
        configuration.preferences.isElementFullscreenEnabled = true
        // ponytail: WKWebView keeps Picture in Picture and the programmatic Web Inspector
        // switched off, and neither has a public setter. These two keys are the whole difference.
        configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.add(MediaMessageHandler(tabID: tab.id), contentWorld: .defaultClient, name: "jungleMedia")
        configuration.userContentController.add(
            DeveloperMetricsMessageHandler(tabID: tab.id),
            contentWorld: .defaultClient,
            name: DeveloperDiagnostics.messageHandlerName
        )
        configuration.userContentController.addUserScript(Self.mediaScript)
        configuration.userContentController.addUserScript(DeveloperDiagnostics.userScript)
        configuration.userContentController.addUserScript(LinkPrewarming.userScript)
        configuration.userContentController.addUserScript(YouTubeAdBlocking.userScript)
        configuration.userContentController.addUserScript(YouTubeAdBlocking.playerScript)
        ContentBlocking.shared.install(on: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        applyContentBackground(isDark: isDark ?? systemAppearanceIsDark, to: webView)
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
    func hostView(for tab: BrowserTab, profile: BrowserProfile, isDark: Bool? = nil) -> NSView {
        if let hostView = hostViews[tab.id] { return hostView }

        let effectiveIsDark = isDark ?? systemAppearanceIsDark
        let webView = webView(for: tab, profile: profile, isDark: effectiveIsDark)
        let hostView = NSView()
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = Self.contentBackground(isDark: effectiveIsDark).cgColor
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = hostView.bounds
        webView.autoresizingMask = [.width, .height]
        hostView.addSubview(webView)
        hostViews[tab.id] = hostView
        return hostView
    }

    func contains(_ tabID: UUID) -> Bool { webViews[tabID] != nil }

    func tabID(for webView: WKWebView) -> UUID? {
        webViews.first(where: { $0.value === webView })?.key
    }

    /// The host view a tab already owns, without bringing a discarded tab back to life.
    func attachedHostView(for tabID: UUID) -> NSView? { hostViews[tabID] }

    func applyContentRuleLists(_ lists: [WKContentRuleList]) {
        webViews.values.forEach { webView in
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            lists.forEach(controller.add(_:))
        }
    }

    /// `width` caps the snapshot: a suspended tab keeps its preview in memory for as long as
    /// it sleeps, and a full-resolution window bitmap costs tens of megabytes per tab.
    func takeSnapshot(of tabID: UUID, width: CGFloat? = nil, completion: @escaping (NSImage?) -> Void) {
        guard let webView = webViews[tabID] else { completion(nil); return }
        let configuration = WKSnapshotConfiguration()
        if let width { configuration.snapshotWidth = NSNumber(value: Double(width)) }
        webView.takeSnapshot(with: configuration) { image, _ in completion(image) }
    }

    func reportDeveloperMetrics(for tabID: UUID) {
        evaluate("window.__jungleDeveloperMetrics && window.__jungleDeveloperMetrics.report()", in: tabID)
    }

    func enterPictureInPicture(for tabID: UUID) async -> Bool {
        await evaluateBoolean("__jungleMedia.enterPictureInPicture()", in: tabID)
    }

    func exitPictureInPicture(for tabID: UUID) async -> Bool {
        await evaluateBoolean("__jungleMedia.exitPictureInPicture()", in: tabID)
    }

    func applyContentBackground(isDark: Bool, to webView: WKWebView) {
        let backgroundColor = Self.contentBackground(isDark: isDark)
        webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
    }

    static func contentBackground(isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .windowBackgroundColor
    }

    private var systemAppearanceIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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

    private func evaluateBoolean(_ script: String, in tabID: UUID) async -> Bool {
        guard let webView = webViews[tabID] else { return false }
        do {
            return (try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? Bool) ?? false
        } catch {
            return false
        }
    }

    /// Tracks the video the page is playing and exposes the presentation-mode calls the
    /// app drives from AppKit. Lives in the client content world so pages cannot see it.
    ///
    /// ponytail: main frame only, which covers YouTube and every site that plays in the
    /// page itself. Videos inside a cross-origin iframe need per-frame evaluation; add it
    /// when a site that matters actually needs it.
    static let mediaScript = WKUserScript(
        source: """
        (function () {
            let activeVideo = null;

            function isPresentable(video) {
                return video instanceof HTMLVideoElement
                    && video.isConnected
                    && typeof video.webkitSetPresentationMode === 'function'
                    && video.webkitSupportsPresentationMode('picture-in-picture');
            }

            function report(isActive) {
                window.webkit.messageHandlers.jungleMedia.postMessage({
                    type: 'pictureInPictureDidChange',
                    isActive: isActive
                });
            }

            document.addEventListener('play', function (event) {
                if (isPresentable(event.target)) { activeVideo = event.target; }
            }, true);

            document.addEventListener('pause', function (event) {
                // Pausing while the page is on screen is the user's call; hiding the page
                // pauses playback on our behalf and must not clear the active video.
                if (event.target === activeVideo && document.visibilityState === 'visible') {
                    activeVideo = null;
                }
            }, true);

            // WebKit answers every presentation change here, whichever side started it:
            // our menu command, the player's own button, or the floating window closing.
            document.addEventListener('webkitpresentationmodechanged', function (event) {
                const video = event.target;
                if (!(video instanceof HTMLVideoElement)) { return; }
                const isActive = video.webkitPresentationMode === 'picture-in-picture';
                if (isActive) { activeVideo = video; }
                report(isActive);
            }, true);

            function playingVideo() {
                if (isPresentable(activeVideo) && !activeVideo.paused && !activeVideo.ended) { return activeVideo; }
                // The page can swap the element out, or start playing before this script ran,
                // so fall back to the largest video that is actually playing right now.
                return Array.prototype.filter.call(document.querySelectorAll('video'), function (video) {
                    return isPresentable(video) && !video.paused && !video.ended && video.readyState >= 2;
                }).sort(function (first, second) {
                    return (second.clientWidth * second.clientHeight) - (first.clientWidth * first.clientHeight);
                })[0] || null;
            }

            function pictureInPictureVideo() {
                return Array.prototype.find.call(
                    document.querySelectorAll('video'),
                    function (video) { return video.webkitPresentationMode === 'picture-in-picture'; }
                ) || null;
            }

            window.__jungleMedia = {
                enterPictureInPicture: function () {
                    if (pictureInPictureVideo()) { return true; }
                    const video = playingVideo();
                    if (!video) { return false; }
                    video.webkitSetPresentationMode('picture-in-picture');
                    return true;
                },
                exitPictureInPicture: function () {
                    const video = pictureInPictureVideo();
                    if (!video) { return false; }
                    video.webkitSetPresentationMode('inline');
                    return true;
                },
                isPictureInPictureActive: function () {
                    return pictureInPictureVideo() !== null;
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

private final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
    private let tabID: UUID

    init(tabID: UUID) {
        self.tabID = tabID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              body["type"] as? String == "pictureInPictureDidChange",
              let isActive = body["isActive"] as? Bool
        else { return }
        NotificationCenter.default.post(
            name: .junglePictureInPictureDidChange,
            object: nil,
            userInfo: ["tabID": tabID, "isActive": isActive]
        )
    }
}
