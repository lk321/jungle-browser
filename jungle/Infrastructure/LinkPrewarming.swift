import Foundation
import WebKit

/// Adds a small, bounded amount of speculative connection work after the user
/// shows intent to leave the current page. WebKit does not reliably support
/// document `prefetch`, so this deliberately warms only DNS and TLS instead of
/// issuing hidden page requests with cookies or side effects.
enum LinkPrewarming {
    static let hoverDelayMilliseconds = 90
    static let maximumPreconnects = 2
    static let maximumDNSPrefetches = 6

    static func isEligibleDestination(_ destination: URL) -> Bool {
        guard destination.scheme?.lowercased() == "https",
              destination.host != nil,
              destination.user == nil,
              destination.password == nil
        else {
            return false
        }
        return true
    }

    static func isCrossOrigin(_ destination: URL, from pageURL: URL) -> Bool {
        origin(of: destination) != origin(of: pageURL)
    }

    static let userScript = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static let scriptSource = """
    (function () {
        'use strict';

        const HOVER_DELAY_MS = \(hoverDelayMilliseconds);
        const MAXIMUM_PRECONNECTS = \(maximumPreconnects);
        const MAXIMUM_DNS_PREFETCHES = \(maximumDNSPrefetches);
        const timers = new WeakMap();
        const preconnects = new Map();
        const dnsPrefetches = new Map();

        function reducedDataIsRequested() {
            const connection = navigator.connection;
            if (connection && connection.saveData) { return true; }
            return window.matchMedia && window.matchMedia('(prefers-reduced-data: reduce)').matches;
        }

        function targetURL(anchor) {
            if (!anchor.href || anchor.hasAttribute('download')) { return null; }
            if (anchor.target && anchor.target.toLowerCase() !== '_self') { return null; }
            if (anchor.dataset.junglePrewarm === 'off') { return null; }

            try {
                const target = new URL(anchor.href, document.baseURI);
                if (target.protocol !== 'https:' || target.username || target.password) { return null; }
                if (target.origin === window.location.origin) { return null; }
                return target;
            } catch (_) {
                return null;
            }
        }

        function appendHint(relation, origin, entries, maximum) {
            if (entries.has(origin)) { return; }

            const hint = document.createElement('link');
            hint.rel = relation;
            hint.href = origin;
            hint.dataset.junglePrewarm = relation;
            if (relation === 'preconnect') { hint.crossOrigin = 'anonymous'; }

            const parent = document.head || document.documentElement;
            if (!parent) { return; }
            parent.appendChild(hint);
            entries.set(origin, hint);

            while (entries.size > maximum) {
                const oldest = entries.entries().next().value;
                if (!oldest) { return; }
                oldest[1].remove();
                entries.delete(oldest[0]);
            }
        }

        function warm(anchor) {
            timers.delete(anchor);
            if (reducedDataIsRequested()) { return; }
            const target = targetURL(anchor);
            if (!target) { return; }

            appendHint('dns-prefetch', target.origin, dnsPrefetches, MAXIMUM_DNS_PREFETCHES);
            appendHint('preconnect', target.origin, preconnects, MAXIMUM_PRECONNECTS);
        }

        function anchorFor(event) {
            const element = event.target;
            return element && typeof element.closest === 'function' ? element.closest('a[href]') : null;
        }

        document.addEventListener('pointerover', function (event) {
            if (event.pointerType && event.pointerType !== 'mouse') { return; }
            const anchor = anchorFor(event);
            if (!anchor || timers.has(anchor) || !targetURL(anchor)) { return; }
            timers.set(anchor, window.setTimeout(function () { warm(anchor); }, HOVER_DELAY_MS));
        }, true);

        document.addEventListener('pointerout', function (event) {
            const anchor = anchorFor(event);
            const relatedTarget = event.relatedTarget;
            if (!anchor || (relatedTarget && relatedTarget.nodeType && anchor.contains(relatedTarget))) { return; }
            const timer = timers.get(anchor);
            if (timer !== undefined) {
                window.clearTimeout(timer);
                timers.delete(anchor);
            }
        }, true);

        document.addEventListener('pointerdown', function (event) {
            if (event.button !== 0 || (event.pointerType && event.pointerType !== 'mouse')) { return; }
            const anchor = anchorFor(event);
            if (anchor) { warm(anchor); }
        }, true);

        window.addEventListener('pagehide', function () {
            preconnects.forEach(function (hint) { hint.remove(); });
            dnsPrefetches.forEach(function (hint) { hint.remove(); });
            preconnects.clear();
            dnsPrefetches.clear();
        }, { once: true });
    })();
    """

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort: Int?
        switch scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: defaultPort = nil
        }
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
