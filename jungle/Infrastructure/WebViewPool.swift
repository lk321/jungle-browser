import AppKit
import AVKit
import WebKit

@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var webViews: [UUID: WKWebView] = [:]
    private var hostViews: [UUID: NSView] = [:]
    /// One store per profile for the whole session. A store WebKit builds fresh for every
    /// tab dies with the last tab of its profile, and with it the network session, the cookie
    /// store and the in-memory HTTP cache — so the next tab paid for a cold connection.
    ///
    /// ponytail: a deleted profile's store stays here until quit. It is a handful of objects,
    /// and nothing removes the profile's data from disk yet either; evict both together.
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    private init() {}

    func webView(for tab: BrowserTab, profile: BrowserProfile, isDark: Bool? = nil) -> WKWebView {
        if let webView = webViews[tab.id] {
            if let isDark { applyContentBackground(isDark: isDark, to: webView) }
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: profile)
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
        configuration.userContentController.add(MediaMessageHandler(), contentWorld: .defaultClient, name: "jungleMedia")
        configuration.userContentController.add(
            DeveloperMetricsMessageHandler(),
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
        addUserScripts(to: configuration.userContentController)
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
    /// The configuration WebKit copies from the opener carries the opener's content controller,
    /// so the popup shares the opener's message handlers. Those handlers look the tab up from
    /// the web view that sent each message, which is what files a popup's first paint, audio and
    /// Picture in Picture under the popup rather than the tab that opened it.
    func adoptPopup(configuration: WKWebViewConfiguration, for tabID: UUID, isDark: Bool? = nil) -> WKWebView {
        let webView = JungleWebView(frame: .zero, configuration: configuration)
        prepare(webView, isDark: isDark ?? systemAppearanceIsDark)
        webViews[tabID] = webView
        return webView
    }

    /// Which of the in-page defences are switched on. Scripts are installed per web view, so
    /// a change here is re-applied to the views that already exist.
    private var adBlocking = AdBlockingOptions()

    func setAdBlockingOptions(_ options: AdBlockingOptions) {
        guard adBlocking != options else { return }
        adBlocking = options
        reinstallUserScripts()
    }

    /// Puts every script back on every open tab, for the next document each one loads.
    func reinstallUserScripts() {
        webViews.values.forEach { webView in
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            addUserScripts(to: controller)
        }
    }

    /// Every script a tab runs, in one place, because switching one off means putting the
    /// rest back: WebKit only removes user scripts all at once.
    ///
    /// ponytail: a script already injected into a loaded page stays until that page goes
    /// away, so a switch flipped mid-browse reaches a tab on its next load. Re-running the
    /// open pages would mean reloading tabs out from under the user.
    private func addUserScripts(to controller: WKUserContentController) {
        controller.addUserScript(WebNotifications.userScript())
        controller.addUserScript(Self.mediaScript)
        controller.addUserScript(MediaKeyRelease.userScript)
        controller.addUserScript(ScreenShareQuality.userScript)
        controller.addUserScript(JungleWebView.contextMenuScript)
        controller.addUserScript(DeveloperDiagnostics.userScript)
        controller.addUserScript(LinkPrewarming.userScript)
        if adBlocking.bypassesAdblockWalls {
            controller.addUserScript(AntiAdblockDefusing.userScript)
        }
        if adBlocking.skipsYouTubeAds {
            controller.addUserScript(YouTubeAdBlocking.userScript)
            controller.addUserScript(YouTubeAdBlocking.playerScript)
        }
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

    private func dataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if let store = dataStores[profile.dataStoreID] { return store }
        let store = WKWebsiteDataStore(forIdentifier: profile.dataStoreID)
        dataStores[profile.dataStoreID] = store
        return store
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

    /// Picture in Picture as WebKit itself tracks it: every frame, every shadow root, whoever
    /// started it. A page script only sees the videos in its own document, so an embedded
    /// player's floating window went unnoticed and its tab was hidden out from under it — the
    /// page kept saying the video was in Picture in Picture while no window was on screen.
    ///
    /// The UI delegate's word comes first. `_isPictureInPictureActive` only covers the video
    /// WebKit's own control manages: for a window opened from a player in an embedded frame it
    /// read false while the delegate had already said true and the window was on screen.
    func isPictureInPictureActive(_ tabID: UUID) -> Bool {
        guard let webView = webViews[tabID] else { return false }
        return pictureInPictureTabIDs.contains(tabID) || Self.privateBool("_isPictureInPictureActive", of: webView)
    }

    private var pictureInPictureTabIDs: Set<UUID> = []

    /// Fed from `_webView:hasVideoInPictureInPictureDidChange:`, ahead of the store.
    func pictureInPictureDidChange(isActive: Bool, tabID: UUID) {
        if isActive {
            pictureInPictureTabIDs.insert(tabID)
        } else {
            pictureInPictureTabIDs.remove(tabID)
        }
    }

    /// Whether this host view's page has a floating window open right now.
    func hostsPictureInPicture(_ hostView: NSView) -> Bool {
        guard let tabID = hostViews.first(where: { $0.value === hostView })?.key else { return false }
        return isPictureInPictureActive(tabID)
    }

    /// Referencing AVKit is what links it, and AVKit brings PIP.framework in at launch. The
    /// App Sandbox only lets a process reach `com.apple.PIPAgent` once PIP.framework is loaded;
    /// WebKit loads it lazily, in the same breath as that lookup, so a build without this was
    /// denied and WebKit never heard back: the page said "playing in Picture in Picture" and no
    /// window came up. A Debug run from Xcode happened to have it loaded already.
    /// `testPictureInPictureFrameworkIsLinked` fails if the reference is optimised away.
    static let supportsPictureInPicture: Bool = AVPictureInPictureController.isPictureInPictureSupported()

    func enterPictureInPicture(for tabID: UUID) async -> Bool {
        guard Self.supportsPictureInPicture, let webView = webViews[tabID] else { return false }
        if isPictureInPictureActive(tabID) { return true }
        // Safari's own Picture in Picture control: WebKit picks the page's main video, in
        // any frame or shadow root, the one the page script cannot reach.
        let toggle: Selector = NSSelectorFromString("_togglePictureInPicture")
        if Self.privateBool("_canTogglePictureInPicture", of: webView), webView.responds(to: toggle) {
            webView.perform(toggle)
            return true
        }
        // WebKit passed the video over, which is what an embedded player gets: anime and video
        // hosts nest theirs two or three cross-origin iframes deep. Each frame that plays a video
        // says so, and that frame is asked directly; a frame that has moved on answers false.
        let script = "window.__jungleMedia ? __jungleMedia.enterPictureInPicture() : false"
        let frames = videoFrames[tabID].map { [$0.audible, $0.latest] } ?? []
        var asked: [WKFrameInfo] = []
        for case let frame? in frames where !asked.contains(where: { $0 === frame }) {
            asked.append(frame)
            if await evaluateBoolean(script, in: webView, frame: frame) { return true }
        }
        return await evaluateBoolean(script, in: webView, frame: nil)
    }

    /// The frames of each tab that last started a video: one with sound, and whichever came
    /// last. An ad frame autoplays muted, so the audible one is asked first — it is the video
    /// the user is watching.
    private var videoFrames: [UUID: (audible: WKFrameInfo?, latest: WKFrameInfo?)] = [:]

    func recordVideoFrame(_ frame: WKFrameInfo, isAudible: Bool, for tabID: UUID) {
        var frames = videoFrames[tabID] ?? (nil, nil)
        frames.latest = frame
        if isAudible { frames.audible = frame }
        videoFrames[tabID] = frames
    }

    func exitPictureInPicture(for tabID: UUID) async -> Bool {
        guard let webView = webViews[tabID], isPictureInPictureActive(tabID) else { return false }
        await webView.closeAllMediaPresentations()
        return true
    }

    /// Reads a private WebKit flag, and answers false if this WebKit has dropped it: an unknown
    /// key would otherwise raise an Objective-C exception Swift cannot catch.
    private static func privateBool(_ name: String, of webView: WKWebView) -> Bool {
        guard webView.responds(to: NSSelectorFromString(name)) else { return false }
        return (webView.value(forKey: name) as? Bool) ?? false
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
        if isPictureInPictureActive(tabID) { completion(true); return }
        webView.evaluateJavaScript("__jungleMedia.holdsPlayback()", in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): completion((value as? Bool) ?? false)
            case .failure: completion(false)
            }
        }
    }

    /// Ends the tab's page and, with it, the web process that page was keeping alive.
    ///
    /// Releasing the web view is not enough: AVKit's Picture in Picture window, a pending
    /// script completion or a snapshot in flight can each still hold the `WKWebView`, and the
    /// page — and its gigabyte of WebContent process — lives exactly as long as that view does.
    /// Closing the page explicitly ends it whoever still holds the view.
    func discard(_ tabID: UUID) {
        // A mute can be recorded for a tab that is already asleep, so these go even when
        // there is no web view left to discard.
        appliedMuteStates.removeValue(forKey: tabID)
        videoFrames.removeValue(forKey: tabID)
        pictureInPictureTabIDs.remove(tabID)
        hostViews.removeValue(forKey: tabID)?.removeFromSuperview()
        guard let webView = webViews.removeValue(forKey: tabID) else { return }
        // Media first, so a Picture in Picture window folds away instead of losing its page.
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        // The script message handlers stay: a popup shares its opener's content controller, so
        // removing them here would silence the opener. A closed page sends nothing, and the
        // controller goes with the last configuration that still points at it.
        Self.closePage(of: webView)
    }

    /// `-[WKWebView _close]` is what Safari calls per tab: it closes the page immediately and
    /// lets WebKit end a web process no other page uses, instead of waiting for the view to
    /// deallocate. It is private, so it is only sent while this WebKit still answers to it —
    /// an unknown selector would raise an Objective-C exception Swift cannot catch.
    private static func closePage(of webView: WKWebView) {
        let close: Selector = NSSelectorFromString("_close")
        guard webView.responds(to: close) else { return }
        webView.perform(close)
    }

    private func evaluate(_ script: String, in tabID: UUID) {
        guard let webView = webViews[tabID] else { return }
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    /// `nil` is the main frame. A frame that has gone away throws, which reads as false.
    private func evaluateBoolean(_ script: String, in webView: WKWebView, frame: WKFrameInfo?) async -> Bool {
        do {
            return (try await webView.evaluateJavaScript(script, in: frame, contentWorld: .defaultClient) as? Bool) ?? false
        } catch {
            return false
        }
    }

    /// Tracks the video each frame is playing, for the videos WebKit's own Picture in Picture
    /// control does not pick, and the tab's audio. Lives in the client content world so pages
    /// cannot see it. Whether a floating window is open is WebKit's to say, not this script's.
    ///
    /// Runs in every frame, because the players that need it are embedded: a frame reports the
    /// video it starts, and the app asks that frame for Picture in Picture. Sound and the tab
    /// mute stay with the main frame, which is the only one the app reads them from.
    ///
    /// ponytail: a frame only reports videos whose `play` reaches its document, and `play` does
    /// not leave a shadow root. The main frame still searches shadow roots when asked; a frame
    /// that needs the same would have to report from inside them.
    static let mediaScript = WKUserScript(
        source: """
        (function () {
            const isTopFrame = window === window.top;
            let activeVideo = null;

            function isPresentable(video) {
                return video instanceof HTMLVideoElement
                    && video.isConnected
                    && typeof video.webkitSetPresentationMode === 'function'
                    && video.webkitSupportsPresentationMode('picture-in-picture');
            }

            function isPlaying(video) {
                return isPresentable(video) && !video.paused && !video.ended;
            }

            function isVideoAudible(video) {
                return !video.muted && video.volume > 0;
            }

            function reportVideo(video) {
                window.webkit.messageHandlers.jungleMedia.postMessage({
                    type: 'videoDidPlay',
                    isAudible: isVideoAudible(video)
                });
            }

            // `playing`, not `play`: a player that calls `play()` right after setting its source
            // fires `play` before the metadata is in, when WebKit still says the video cannot
            // go to Picture in Picture.
            document.addEventListener('playing', function (event) {
                if (!isPresentable(event.target)) { return; }
                activeVideo = event.target;
                reportVideo(activeVideo);
            }, true);

            // A player that starts muted and is unmuted by the user becomes the video to float.
            document.addEventListener('volumechange', function (event) {
                if (isPlaying(event.target) && isVideoAudible(event.target)) { reportVideo(event.target); }
            }, true);

            document.addEventListener('pause', function (event) {
                // Pausing while the page is on screen is the user's call; hiding the page
                // pauses playback on our behalf and must not clear the active video.
                if (event.target === activeVideo && document.visibilityState === 'visible') {
                    activeVideo = null;
                }
            }, true);

            // Every video in this frame, shadow roots included. Walked only when Picture in
            // Picture is asked for, never per event.
            function allVideos() {
                const found = [];
                const roots = [document];
                while (roots.length) {
                    const walker = document.createTreeWalker(roots.pop(), NodeFilter.SHOW_ELEMENT);
                    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                        if (node instanceof HTMLVideoElement) { found.push(node); }
                        if (node.shadowRoot) { roots.push(node.shadowRoot); }
                    }
                }
                return found;
            }

            function playingVideo() {
                if (isPlaying(activeVideo)) { return activeVideo; }
                // The page can swap the element out, or start playing before this script ran,
                // so fall back to the video actually playing right now: one with sound over a
                // muted one, then the largest.
                return allVideos().filter(function (video) {
                    return isPlaying(video) && video.readyState >= 2;
                }).sort(function (first, second) {
                    const sound = Number(isVideoAudible(second)) - Number(isVideoAudible(first));
                    if (sound !== 0) { return sound; }
                    return (second.clientWidth * second.clientHeight) - (first.clientWidth * first.clientHeight);
                })[0] || null;
            }

            function enterPictureInPicture() {
                const video = playingVideo();
                if (!video) { return false; }
                // The user asked for it; a player's opt-out is not theirs to overrule.
                if (video.disablePictureInPicture) { video.disablePictureInPicture = false; }
                video.webkitSetPresentationMode('picture-in-picture');
                return true;
            }

            if (!isTopFrame) {
                window.__jungleMedia = { enterPictureInPicture: enterPictureInPicture };
                return;
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
                enterPictureInPicture: enterPictureInPicture,
                // Only what the user would miss keeps the web process: sound here, and a
                // Picture in Picture window, which WebKit reports on its own. A hero video or an ad the page muted itself autoplays
                // forever, and holding its tab for that pinned the page's memory for good.
                // The tab mute does not count as silence — the user muted it and still wants
                // it to keep playing.
                holdsPlayback: function () {
                    return Array.prototype.some.call(mediaElements(), function (media) {
                        if (media.paused || media.ended || media.volume === 0) { return false; }
                        return !media.muted || mutedByTab.has(media);
                    });
                }
            };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .defaultClient
    )
}

/// Shared by an opener and every popup it adopts, so the tab is whichever one sent the message.
private final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let webView = message.webView,
              let tabID = WebViewPool.shared.tabID(for: webView)
        else { return }
        switch body["type"] as? String {
        case "audioDidChange":
            guard let isAudible = body["isAudible"] as? Bool else { return }
            NotificationCenter.default.post(
                name: .jungleAudioDidChange,
                object: nil,
                userInfo: ["tabID": tabID, "isAudible": isAudible]
            )
        case "videoDidPlay":
            WebViewPool.shared.recordVideoFrame(
                message.frameInfo,
                isAudible: body["isAudible"] as? Bool ?? false,
                for: tabID
            )
        default:
            return
        }
    }
}
