import Foundation
import WebKit

/// Answers the pages that refuse to work while an ad blocker is on.
///
/// Two things make a page say "disable AdBlock": a detector that reports the blocker, and the
/// nag it puts on screen afterwards. This handles both without knowing any site: the detector
/// libraries almost every nag is built on are given a stub that always reports ads are running,
/// and a nag that still appears is taken off the page along with the scroll lock it came with.
///
/// ponytail: no filter-list syntax and no permanent observer. Nags appear on load or right
/// after a click, so the sweep runs a few times at the start and shortly after a click, and
/// then stops costing anything. Deliberately does not lie about element geometry: a detector
/// that measures a hidden bait element still wins, and faking layout numbers breaks real pages.
enum AntiAdblockDefusing {
    /// Runs in the page's own world, because the values a page reads have to be the page's own,
    /// and in every frame, because these players live inside an iframe.
    static let userScript = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )

    static let scriptSource = """
    (function () {
        'use strict';

        // A page asking any of these is asking "is an ad blocker on?". The answer is no.
        var FLAGS = {
            canRunAds: true,
            canShowAds: true,
            isAdBlockActive: false,
            adBlockDetected: false,
            adblockDetected: false,
            google_ad_status: 1
        };

        function pin(name, value) {
            try {
                Object.defineProperty(window, name, {
                    configurable: true,
                    get: function () { return value; },
                    // The real detector loads after this and would otherwise replace the
                    // answer with its own. Writes are accepted and dropped.
                    set: function () {}
                });
            } catch (_) {
                try { window[name] = value; } catch (_) {}
            }
        }

        Object.keys(FLAGS).forEach(function (name) { pin(name, FLAGS[name]); });

        // Google's tag: the queue it would have created, so a page that pushes into it works.
        try { if (!window.adsbygoogle) { window.adsbygoogle = []; } } catch (_) {}

        // FuckAdBlock and BlockAdBlock, and the copies of them that ship under other names.
        // Their whole API is "tell me when you detect a blocker" — this one never does, and
        // answers the opposite callback instead, which is the branch that shows the video.
        function Defused() { return makeDetector(); }

        function makeDetector() {
            var notDetected = [];
            function later(callback) {
                if (typeof callback === 'function') { setTimeout(callback, 0); }
            }
            var detector = {
                // Kept so `on('detected')` style calls stay chainable; never invoked.
                onDetected: function () { return detector; },
                onNotDetected: function (callback) { notDetected.push(callback); later(callback); return detector; },
                on: function (detected, callback) {
                    if (detected === false || detected === 'notDetected') { return detector.onNotDetected(callback); }
                    return detector;
                },
                check: function () { notDetected.forEach(later); return true; },
                clearEvent: function () { notDetected = []; return detector; },
                setOption: function () { return detector; },
                options: {},
                version: '3.2.1'
            };
            return detector;
        }

        ['FuckAdBlock', 'BlockAdBlock', 'DetectAdBlock', 'AdBlockDetector'].forEach(function (name) {
            pin(name, Defused);
        });
        ['fuckAdBlock', 'blockAdBlock', 'adBlockDetector'].forEach(function (name) {
            pin(name, makeDetector());
        });

        // A nag that got created anyway. Matched on what it says, in the languages these
        // sites use, and only when it is laid over the page rather than part of it.
        var NAG = /(ad\\s?-?blocker?|bloqueador (de )?(anuncios|publicidad)|desactiva.{0,20}(adblock|bloqueador)|disable.{0,20}ad\\s?-?block)/i;
        var SCROLL_LOCK = /(modal-open|no-?scroll|overflow-hidden|blocked|nad|fancybox-active)/i;

        function isLaidOverThePage(element) {
            var style = window.getComputedStyle(element);
            if (style.position !== 'fixed' && style.position !== 'absolute') { return false; }
            if (style.display === 'none' || style.visibility === 'hidden') { return false; }
            var box = element.getBoundingClientRect();
            var coversThePage = box.width >= window.innerWidth * 0.5
                && box.height >= window.innerHeight * 0.35;
            var sitsOnTop = (parseInt(style.zIndex, 10) || 0) >= 100;
            return coversThePage || sitsOnTop;
        }

        // Only the top few levels: an overlay is parked near the root, and walking the whole
        // document on every sweep is the cost this is trying not to have.
        function shallowElements() {
            var found = [];
            var level = document.body ? [].slice.call(document.body.children) : [];
            for (var depth = 0; depth < 3 && level.length; depth++) {
                found = found.concat(level);
                var next = [];
                level.forEach(function (element) {
                    next = next.concat([].slice.call(element.children));
                });
                level = next.length > 400 ? [] : next;
            }
            return found;
        }

        function giveThePageBack() {
            [document.documentElement, document.body].forEach(function (element) {
                if (!element) { return; }
                var style = window.getComputedStyle(element);
                if (style.overflow === 'hidden' || style.position === 'fixed') {
                    element.style.setProperty('overflow', 'auto', 'important');
                    element.style.setProperty('position', 'static', 'important');
                }
                [].slice.call(element.classList).forEach(function (name) {
                    if (SCROLL_LOCK.test(name)) { element.classList.remove(name); }
                });
                if (window.getComputedStyle(element).pointerEvents === 'none') {
                    element.style.setProperty('pointer-events', 'auto', 'important');
                }
            });
        }

        function sweep() {
            if (!document.body) { return; }
            var removedOne = false;
            shallowElements().forEach(function (element) {
                if (!element.isConnected || !NAG.test(element.textContent || '')) { return; }
                // The match has to be this element's own doing, not a child's: removing the
                // outermost match would take the page with it.
                if ([].slice.call(element.children).some(function (child) {
                    return NAG.test(child.textContent || '');
                })) { return; }
                var overlay = element;
                while (overlay.parentElement && overlay.parentElement !== document.body
                       && !isLaidOverThePage(overlay)) {
                    overlay = overlay.parentElement;
                }
                if (!isLaidOverThePage(overlay)) { return; }
                overlay.remove();
                removedOne = true;
            });
            if (removedOne) { giveThePageBack(); }
        }

        // Load, then a short tail for the ones that arrive with the page's own scripts.
        [0, 600, 1500, 3000, 6000].forEach(function (delay) { setTimeout(sweep, delay); });

        // And once after a click, which is when a player puts its nag up. Throttled so a
        // burst of clicks is still one sweep.
        var pending = false;
        document.addEventListener('click', function () {
            if (pending) { return; }
            pending = true;
            setTimeout(function () { pending = false; sweep(); }, 500);
        }, true);
    })();
    """
}
