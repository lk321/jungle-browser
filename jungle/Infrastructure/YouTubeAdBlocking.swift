import Foundation
import WebKit

/// Content rules block ad hosts, and YouTube's in-video ads come from the same host as the
/// video itself, so no network list can touch them. This skips them in the page instead:
/// the player marks an ad with `ad-showing`, and seeking an ad to its end ends it.
///
/// ponytail: no filter-list syntax, no cosmetic engine — a style rule for the static slots
/// and one seek for the in-video ads. Both are what the site itself exposes.
enum YouTubeAdBlocking {
    /// Runs in the page's own world — the only place it can reach the player's JavaScript —
    /// and takes the ad schedule out of the player response before the player ever reads it.
    /// Nothing privileged lives here: no message handlers, no app state.
    static let playerScript = WKUserScript(
        source: playerScriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )

    static let userScript = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .defaultClient
    )

    /// `adPlacements` is what schedules the pre-roll and mid-rolls; the player finds nothing
    /// to play when it is gone. The seek in `scriptSource` stays for ads stitched server side.
    static let playerScriptSource = """
    (function () {
        'use strict';

        if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) { return; }

        const AD_KEYS = ['adPlacements', 'playerAds', 'adSlots'];

        function stripAds(value) {
            if (!value || typeof value !== 'object') { return value; }
            for (const key of AD_KEYS) {
                if (key in value) { delete value[key]; }
            }
            return value;
        }

        // The first video's ads ride along in the inline player response.
        try {
            let playerResponse;
            Object.defineProperty(window, 'ytInitialPlayerResponse', {
                configurable: true,
                get: function () { return playerResponse; },
                set: function (value) { playerResponse = stripAds(value); }
            });
        } catch (_) {}

        // Every later video is fetched as JSON while browsing the site.
        const nativeParse = JSON.parse;
        JSON.parse = function (text, reviver) { return stripAds(nativeParse(text, reviver)); };

        const nativeJSON = Response.prototype.json;
        Response.prototype.json = function () { return nativeJSON.call(this).then(stripAds); };
    })();
    """

    static let hiddenSelectors = [
        "#masthead-ad",
        "#player-ads",
        "ytd-ad-slot-renderer",
        "ytd-banner-promo-renderer",
        "ytd-display-ad-renderer",
        "ytd-in-feed-ad-layout-renderer",
        "ytd-promoted-sparkles-web-renderer",
        "ytd-promoted-video-renderer",
        ".ytp-ad-overlay-container",
        ".ytp-ad-overlay-slot",
        ".ytd-companion-slot-renderer"
    ]

    static let scriptSource = """
    (function () {
        'use strict';

        if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) { return; }

        const HIDDEN_SELECTORS = '\(hiddenSelectors.joined(separator: ","))';
        const SKIP_BUTTONS = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button';
        const mutedByUs = new WeakSet();

        function hideStaticAds() {
            const parent = document.head || document.documentElement;
            if (!parent || document.getElementById('jungle-ad-style')) { return; }
            const style = document.createElement('style');
            style.id = 'jungle-ad-style';
            style.textContent = HIDDEN_SELECTORS + '{display:none !important;}';
            parent.appendChild(style);
        }

        function skipVideoAd(video) {
            const player = video.closest('#movie_player, .html5-video-player');
            if (!player) { return; }

            if (!player.classList.contains('ad-showing')) {
                // Give the sound back to the real video, never to one the user muted.
                if (mutedByUs.has(video)) {
                    mutedByUs.delete(video);
                    video.muted = false;
                }
                return;
            }

            const skip = player.querySelector(SKIP_BUTTONS);
            if (skip) { skip.click(); return; }

            // Seeking to the end is what actually ends an unskippable ad; muting keeps the
            // jump from being audible on ads too short to seek out of.
            if (Number.isFinite(video.duration) && video.duration > 0) {
                if (!video.muted) {
                    mutedByUs.add(video);
                    video.muted = true;
                }
                video.currentTime = video.duration;
            }
        }

        // Driven by the ad's own playback: no polling timer and no page-wide observer.
        document.addEventListener('timeupdate', function (event) {
            if (event.target instanceof HTMLVideoElement) { skipVideoAd(event.target); }
        }, true);

        document.addEventListener('loadedmetadata', function (event) {
            if (event.target instanceof HTMLVideoElement) { skipVideoAd(event.target); }
        }, true);

        hideStaticAds();
        document.addEventListener('DOMContentLoaded', hideStaticAds, { once: true });
    })();
    """
}
