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
        // WebKit defaults this to true on macOS, which is what lets an ad script call
        // `window.open` from a timer or a page load with no click behind it. Off, WebKit
        // itself refuses those and only a real user gesture can still open a window.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // ponytail: WKWebView keeps Picture in Picture and the programmatic Web Inspector
        // switched off, and neither has a public setter. These two keys are the whole difference.
        configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Camera, microphone, WebRTC and screen sharing. WKWebView keeps these behind private
        // feature flags, so each one is written only if this WebKit still answers to it.
        ["mediaDevicesEnabled", "mediaStreamEnabled", "peerConnectionEnabled", "screenCaptureEnabled"]
            .forEach { Self.enablePrivatePreference($0, on: configuration.preferences) }
        configuration.userContentController.add(MediaMessageHandler(tabID: tab.id), contentWorld: .defaultClient, name: "jungleMedia")
        configuration.userContentController.add(
            DeveloperMetricsMessageHandler(tabID: tab.id),
            contentWorld: .defaultClient,
            name: DeveloperDiagnostics.messageHandlerName
        )
        configuration.userContentController.add(
            ContextMenuMessageHandler(),
            contentWorld: .defaultClient,
            name: JungleWebView.contextMenuHandlerName
        )
        // The website notification API lives in the page's own world: a page cannot see the
        // client world, and an API it cannot see is an API it cannot use.
        configuration.userContentController.add(
            NotificationMessageHandler(),
            contentWorld: .page,
            name: WebNotifications.handlerName
        )
        configuration.userContentController.addUserScript(WebNotifications.userScript)
        configuration.userContentController.addUserScript(Self.mediaScript)
        configuration.userContentController.addUserScript(JungleWebView.contextMenuScript)
        configuration.userContentController.addUserScript(DeveloperDiagnostics.userScript)
        configuration.userContentController.addUserScript(LinkPrewarming.userScript)
        configuration.userContentController.addUserScript(AntiAdblockDefusing.userScript)
        configuration.userContentController.addUserScript(YouTubeAdBlocking.userScript)
        configuration.userContentController.addUserScript(YouTubeAdBlocking.playerScript)
        ContentBlocking.shared.install(on: configuration.userContentController)

        let webView = JungleWebView(frame: .zero, configuration: configuration)
        prepare(webView, isDark: isDark ?? systemAppearanceIsDark)
        webViews[tab.id] = webView
        return webView
    }

    /// The web view a page asked for with `window.open` or a `target="_blank"` link. WebKit
    /// requires the configuration it handed over to be the one the new view is built from, and
    /// it navigates the view itself, so the tab this belongs to must never load its address a
    /// second time.
    ///
    /// ponytail: the configuration WebKit copies from the opener carries the opener's content
    /// controller, so audio and developer metrics a popup reports are filed under the tab that
    /// opened it. Rebinding those handlers would rebind the opener's too. Split them when a
    /// popup that keeps playing something actually needs its own speaker.
    func adoptPopup(configuration: WKWebViewConfiguration, for tabID: UUID, isDark: Bool? = nil) -> WKWebView {
        let webView = JungleWebView(frame: .zero, configuration: configuration)
        prepare(webView, isDark: isDark ?? systemAppearanceIsDark)
        webViews[tabID] = webView
        return webView
    }

    private func prepare(_ webView: JungleWebView, isDark: Bool) {
        applyContentBackground(isDark: isDark, to: webView)
        webView.customUserAgent = Self.safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
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

    /// A Safari user agent carrying this system's version. Google Sheets halves the resolution
    /// of its grid canvas for a Safari it reads as old: a frozen `Version/18.6` had the grid
    /// drawing 620 by 404 pixels into a 1240 by 808 box, which is what looked blurry. The
    /// version this builds renders the same grid at the full 2478 by 1614.
    ///
    /// ponytail: the version is read from the system rather than written down, because a
    /// number written down is the number that went stale and caused this. It tracks the OS
    /// major and minor, which Safari has shipped alongside since macOS 26 — the oldest system
    /// the app runs on. Safari itself also sends its patch component, and Sheets does not
    /// care: the two-part version was measured rendering at full resolution.
    static let safariUserAgent: String = {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(system.majorVersion).\(system.minorVersion) Safari/605.1.15"
    }()

    /// Writes a private WebKit preference, and does nothing if this WebKit has dropped it:
    /// an unknown key would otherwise raise an Objective-C exception Swift cannot catch.
    private static func enablePrivatePreference(_ key: String, on preferences: WKPreferences) {
        let capitalized = key.prefix(1).uppercased() + key.dropFirst()
        guard preferences.responds(to: NSSelectorFromString("set\(capitalized):"))
            || preferences.responds(to: NSSelectorFromString("_set\(capitalized):"))
        else { return }
        preferences.setValue(true, forKey: key)
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

    /// The last mute the tab was told to apply, kept so a caller can tell whether a resumed
    /// or reloaded document has been re-muted yet.
    private(set) var appliedMuteStates: [UUID: Bool] = [:]

    func forgetAppliedMuteState(for tabID: UUID) {
        appliedMuteStates.removeValue(forKey: tabID)
    }

    func setMuted(_ muted: Bool, in tabID: UUID) {
        appliedMuteStates[tabID] = muted
        evaluate("__jungleMedia.setMuted(\(muted))", in: tabID)
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
        appliedMuteStates.removeValue(forKey: tabID)
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

            let muted = false;
            let reportedAudible = null;

            function mediaElements() {
                return document.querySelectorAll('video, audio');
            }

            // Deliberately ignores `muted`: a muted tab still needs its speaker control on
            // screen so the user can turn the sound back on.
            function isAudible(media) {
                return !media.paused && !media.ended && media.volume > 0;
            }

            // The tab mute only ever silences. A page that mutes itself, or a speaker button
            // the user presses inside the player, has to survive: writing `muted` in both
            // directions here undid every in-page mute on the next `volumechange`.
            const mutedByTab = new WeakSet();

            function applyMuted() {
                // Only write when it differs, or the volumechange listener below re-enters.
                Array.prototype.forEach.call(mediaElements(), function (media) {
                    if (muted) {
                        if (media.muted) { return; }
                        mutedByTab.add(media);
                        media.muted = true;
                        return;
                    }
                    // Give the sound back only to what this tab silenced, never to a video
                    // the page or the user muted on its own.
                    if (!mutedByTab.has(media)) { return; }
                    mutedByTab.delete(media);
                    media.muted = false;
                });
            }

            function reportAudio() {
                const audible = Array.prototype.some.call(mediaElements(), isAudible);
                if (audible === reportedAudible) { return; }
                reportedAudible = audible;
                window.webkit.messageHandlers.jungleMedia.postMessage({
                    type: 'audioDidChange',
                    isAudible: audible
                });
            }

            // A page swaps its media elements as it plays through a playlist, so every new
            // element has to inherit the tab's mute rather than start unmuted.
            ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'loadstart'].forEach(function (name) {
                document.addEventListener(name, function () {
                    applyMuted();
                    reportAudio();
                }, true);
            });

            window.__jungleMedia = {
                setMuted: function (value) {
                    muted = value === true;
                    applyMuted();
                    return muted;
                },
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
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "pictureInPictureDidChange":
            guard let isActive = body["isActive"] as? Bool else { return }
            NotificationCenter.default.post(
                name: .junglePictureInPictureDidChange,
                object: nil,
                userInfo: ["tabID": tabID, "isActive": isActive]
            )
        case "audioDidChange":
            guard let isAudible = body["isAudible"] as? Bool else { return }
            NotificationCenter.default.post(
                name: .jungleAudioDidChange,
                object: nil,
                userInfo: ["tabID": tabID, "isAudible": isAudible]
            )
        default:
            return
        }
    }
}
