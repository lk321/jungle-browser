import Foundation
import WebKit

enum DeveloperDiagnostics {
    static let messageHandlerName = "jungleDeveloperMetrics"

    /// What the page reports over the diagnostics channel. The two kinds share one handler
    /// because they share one injected script.
    enum Message {
        case firstContentfulPaint
        case metrics(DeveloperMetrics)
    }

    static let userScript = WKUserScript(
        source: """
        (function () {
            function integer(value) {
                return typeof value === 'number' && Number.isFinite(value)
                    ? Math.max(0, Math.round(value))
                    : 0;
            }

            // Stack detection is developer-facing, so it stays behind the same local
            // origin gate the toolbar uses: ordinary browsing never pays for these probes.
            function technologies(resources) {
                const host = location.hostname;
                if (host !== 'localhost' && host !== '127.0.0.1') { return []; }

                const signals = [];
                function probe(signal, present) { if (present) { signals.push(signal); } }
                function asset(fragment) {
                    return resources.some(function (resource) { return resource.name.indexOf(fragment) !== -1; });
                }
                function reactRoot() {
                    const containers = document.querySelectorAll('#root, #__next, #app, body > div');
                    for (let index = 0; index < containers.length && index < 5; index += 1) {
                        const keys = Object.keys(containers[index]);
                        if (keys.some(function (key) { return key.indexOf('__react') === 0; })) { return true; }
                    }
                    return false;
                }

                probe('next.data', !!window.__NEXT_DATA__);
                probe('next.assets', asset('/_next/'));
                probe('nuxt', !!window.__NUXT__ || !!window.$nuxt);
                probe('sveltekit', !!document.querySelector('[data-sveltekit-preload-data]'));
                probe('remix', !!window.__remixContext);
                probe('astro', !!document.querySelector('astro-island'));
                // The hook exists whenever the React DevTools extension is installed, so a
                // registered renderer is what actually proves the page is running React.
                const reactHook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
                probe('react.hook', !!(reactHook && reactHook.renderers && reactHook.renderers.size > 0));
                probe('react.root', reactRoot());
                probe('vue.runtime', !!window.__VUE__);
                probe('vue.app', !!document.querySelector('[data-v-app]'));
                probe('svelte', !!window.__svelte);
                probe('angular', !!document.querySelector('[ng-version]'));
                probe('solid', !!window._$HY);
                probe('vite', asset('/@vite/'));
                probe('rails', !!document.querySelector('meta[name="csrf-param"][content="authenticity_token"]'));
                probe('django', document.cookie.indexOf('csrftoken=') !== -1);

                return signals;
            }

            function report() {
                const resources = performance.getEntriesByType('resource');
                const resourceCounts = new Map();
                let transferredBytes = 0;

                for (const resource of resources) {
                    const name = resource.name;
                    resourceCounts.set(name, (resourceCounts.get(name) || 0) + 1);
                    transferredBytes += integer(resource.transferSize || resource.encodedBodySize);
                }

                let repeatedRequestCount = 0;
                for (const count of resourceCounts.values()) {
                    repeatedRequestCount += Math.max(0, count - 1);
                }

                const navigation = performance.getEntriesByType('navigation')[0];
                const memory = performance.memory;
                const payload = {
                    type: 'metrics',
                    pageURL: location.href,
                    requestCount: resources.length + 1,
                    repeatedRequestCount: repeatedRequestCount,
                    transferredBytes: transferredBytes,
                    javaScriptHeapBytes: memory && typeof memory.usedJSHeapSize === 'number'
                        ? integer(memory.usedJSHeapSize)
                        : null,
                    documentNodeCount: document.getElementsByTagName('*').length,
                    loadDurationMilliseconds: navigation ? integer(navigation.duration) : null,
                    technologies: technologies(resources)
                };

                window.webkit.messageHandlers.jungleDeveloperMetrics.postMessage(JSON.stringify(payload));
            }

            // The moment the new document has real pixels on screen. Jungle uncovers the web
            // view here rather than at load completion, which on a content-heavy page lands
            // seconds later. `buffered` covers the entry that landed before this script ran.
            function watchFirstContentfulPaint() {
                const observer = new PerformanceObserver(function (list) {
                    for (const entry of list.getEntries()) {
                        if (entry.name !== 'first-contentful-paint') { continue; }
                        observer.disconnect();
                        window.webkit.messageHandlers.jungleDeveloperMetrics.postMessage(
                            JSON.stringify({ type: 'paint' })
                        );
                        return;
                    }
                });
                observer.observe({ type: 'paint', buffered: true });
            }

            window.__jungleDeveloperMetrics = { report: report };
            window.addEventListener('load', function () {
                report();
                window.setTimeout(report, 250);
            }, { once: true });
            // Last, so a PerformanceObserver this engine dislikes cannot take the metrics
            // report down with it.
            watchFirstContentfulPaint();
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static func message(from body: String) -> Message? {
        guard let data = body.data(using: .utf8),
              let kind = try? JSONDecoder().decode(Envelope.self, from: data).type
        else { return nil }
        if kind == "paint" { return .firstContentfulPaint }
        guard kind == "metrics", let metrics = metrics(from: data) else { return nil }
        return .metrics(metrics)
    }

    private static func metrics(from data: Data) -> DeveloperMetrics? {
        guard let payload = try? JSONDecoder().decode(MetricsPayload.self, from: data),
              let pageURL = URL(string: payload.pageURL)
        else { return nil }

        return DeveloperMetrics(
            pageURL: pageURL,
            requestCount: max(0, payload.requestCount),
            repeatedRequestCount: min(max(0, payload.repeatedRequestCount), max(0, payload.requestCount - 1)),
            transferredBytes: max(0, payload.transferredBytes),
            javaScriptHeapBytes: payload.javaScriptHeapBytes.map { max(0, $0) },
            documentNodeCount: max(0, payload.documentNodeCount),
            loadDurationMilliseconds: payload.loadDurationMilliseconds.map { max(0, $0) },
            technologies: technologies(from: payload.technologies ?? [])
        )
    }

    private struct Envelope: Decodable {
        let type: String
    }

    /// Page signals mapped to what they actually prove. Ordered so meta frameworks read
    /// before the library they wrap, and first signal per name wins: React detected twice
    /// is still one chip, and the chip names the strongest reason we saw it.
    private static let technologySignals: [(signal: String, name: String, detail: String)] = [
        ("next.data", "Next.js", "the __NEXT_DATA__ payload"),
        ("next.assets", "Next.js", "/_next/ assets"),
        ("nuxt", "Nuxt", "the __NUXT__ payload"),
        ("sveltekit", "SvelteKit", "the data-sveltekit-preload-data attribute"),
        ("remix", "Remix", "the __remixContext global"),
        ("astro", "Astro", "astro-island elements"),
        ("react.hook", "React", "the __REACT_DEVTOOLS_GLOBAL_HOOK__ global"),
        ("react.root", "React", "a React root container"),
        ("vue.runtime", "Vue", "the __VUE__ runtime flag"),
        ("vue.app", "Vue", "the data-v-app mount attribute"),
        ("svelte", "Svelte", "the __svelte development global"),
        ("angular", "Angular", "the ng-version attribute"),
        ("solid", "Solid", "the _$HY hydration store"),
        ("vite", "Vite", "the /@vite/ client module"),
        ("rails", "Ruby on Rails", "the authenticity_token CSRF meta tag"),
        ("django", "Django", "the csrftoken cookie")
    ]

    static func technologies(from signals: [String]) -> [DetectedTechnology] {
        var named: Set<String> = []
        return technologySignals.compactMap { entry in
            guard signals.contains(entry.signal), named.insert(entry.name).inserted else { return nil }
            return DetectedTechnology(name: entry.name, detail: entry.detail)
        }
    }

    private struct MetricsPayload: Decodable {
        let pageURL: String
        let requestCount: Int
        let repeatedRequestCount: Int
        let transferredBytes: Int64
        let javaScriptHeapBytes: Int64?
        let documentNodeCount: Int
        let loadDurationMilliseconds: Int?
        let technologies: [String]?
    }
}

final class DeveloperMetricsMessageHandler: NSObject, WKScriptMessageHandler {
    private let tabID: UUID

    init(tabID: UUID) {
        self.tabID = tabID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let decoded = DeveloperDiagnostics.message(from: body)
        else { return }

        let tabID = self.tabID
        Task { @MainActor in
            switch decoded {
            case .firstContentfulPaint:
                NotificationCenter.default.post(
                    name: .jungleFirstContentfulPaint,
                    object: nil,
                    userInfo: ["tabID": tabID]
                )
            case .metrics(let metrics):
                NotificationCenter.default.post(
                    name: .jungleDeveloperMetricsDidUpdate,
                    object: nil,
                    userInfo: ["tabID": tabID, "metrics": metrics]
                )
            }
        }
    }
}
