import Foundation
import WebKit

enum DeveloperDiagnostics {
    static let messageHandlerName = "jungleDeveloperMetrics"

    static let userScript = WKUserScript(
        source: """
        (function () {
            function integer(value) {
                return typeof value === 'number' && Number.isFinite(value)
                    ? Math.max(0, Math.round(value))
                    : 0;
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
                    pageURL: location.href,
                    requestCount: resources.length + 1,
                    repeatedRequestCount: repeatedRequestCount,
                    transferredBytes: transferredBytes,
                    javaScriptHeapBytes: memory && typeof memory.usedJSHeapSize === 'number'
                        ? integer(memory.usedJSHeapSize)
                        : null,
                    documentNodeCount: document.getElementsByTagName('*').length,
                    loadDurationMilliseconds: navigation ? integer(navigation.duration) : null
                };

                window.webkit.messageHandlers.jungleDeveloperMetrics.postMessage(JSON.stringify(payload));
            }

            window.__jungleDeveloperMetrics = { report: report };
            window.addEventListener('load', function () {
                report();
                window.setTimeout(report, 250);
            }, { once: true });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static func metrics(from message: String) -> DeveloperMetrics? {
        guard let data = message.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MetricsPayload.self, from: data),
              let pageURL = URL(string: payload.pageURL)
        else { return nil }

        return DeveloperMetrics(
            pageURL: pageURL,
            requestCount: max(0, payload.requestCount),
            repeatedRequestCount: min(max(0, payload.repeatedRequestCount), max(0, payload.requestCount - 1)),
            transferredBytes: max(0, payload.transferredBytes),
            javaScriptHeapBytes: payload.javaScriptHeapBytes.map { max(0, $0) },
            documentNodeCount: max(0, payload.documentNodeCount),
            loadDurationMilliseconds: payload.loadDurationMilliseconds.map { max(0, $0) }
        )
    }

    private struct MetricsPayload: Decodable {
        let pageURL: String
        let requestCount: Int
        let repeatedRequestCount: Int
        let transferredBytes: Int64
        let javaScriptHeapBytes: Int64?
        let documentNodeCount: Int
        let loadDurationMilliseconds: Int?
    }
}

final class DeveloperMetricsMessageHandler: NSObject, WKScriptMessageHandler {
    private let tabID: UUID

    init(tabID: UUID) {
        self.tabID = tabID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let encodedMetrics = message.body as? String,
              let metrics = DeveloperDiagnostics.metrics(from: encodedMetrics)
        else { return }

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .jungleDeveloperMetricsDidUpdate,
                object: nil,
                userInfo: ["tabID": self.tabID, "metrics": metrics]
            )
        }
    }
}
