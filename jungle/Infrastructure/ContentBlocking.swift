import CryptoKit
import Foundation
import WebKit

/// Keeps native WebKit content rules current without putting a per-request
/// interceptor in the browsing path. The public EasyList and EasyPrivacy feeds
/// are parsed into their safe, host-anchored network rules only; unsupported
/// filter syntax is deliberately ignored rather than guessed.
@MainActor
final class ContentBlocking {
    static let shared = ContentBlocking()

    private struct Feed: Sendable {
        let key: String
        let url: URL

        init?(key: String, urlString: String) {
            guard let url = URL(string: urlString) else { return nil }
            self.key = key
            self.url = url
        }
    }

    private static let feeds = [
        Feed(key: "ads", urlString: "https://easylist.to/easylist/easylist.txt"),
        Feed(key: "privacy", urlString: "https://easylist.to/easylist/easyprivacy.txt")
    ].compactMap { $0 }

    private let store = WKContentRuleListStore.default()
    private let defaults = UserDefaults.standard
    private var activeLists: [String: WKContentRuleList] = [:]
    private var updateTask: Task<Void, Never>?

    private init() {}

    deinit { updateTask?.cancel() }

    func start() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.restoreCachedLists()
            await self.installBootstrapRulesIfNeeded()
            await self.refreshIfDue()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard !Task.isCancelled else { return }
                await self.refreshIfDue()
            }
        }
    }

    func install(on controller: WKUserContentController) {
        activeLists.values.forEach(controller.add(_:))
    }

    private func restoreCachedLists() async {
        for key in ["bootstrap"] + Self.feeds.map(\.key) {
            guard let identifier = defaults.string(forKey: identifierKey(for: key)),
                  let list = await lookUp(identifier: identifier) else { continue }
            activeLists[key] = list
        }
        applyActiveLists()
    }

    private func installBootstrapRulesIfNeeded() async {
        guard activeLists["bootstrap"] == nil else { return }
        let source = ContentBlockerRuleCompiler.compile(
            Self.bootstrapDomains.map { "||\($0)^$third-party" }.joined(separator: "\n"),
            maximumRuleCount: Self.bootstrapDomains.count
        )
        await compileAndActivate(source, key: "bootstrap")
    }

    private func refreshIfDue() async {
        guard shouldRefresh else { return }

        var didUpdate = false
        for feed in Self.feeds {
            didUpdate = await refresh(feed) || didUpdate
        }
        if didUpdate { defaults.set(Date.now, forKey: "contentBlocking.lastRefresh") }
    }

    private var shouldRefresh: Bool {
        guard let date = defaults.object(forKey: "contentBlocking.lastRefresh") as? Date else { return true }
        return Date.now.timeIntervalSince(date) >= 60 * 60 * 24
    }

    private func refresh(_ feed: Feed) async -> Bool {
        var request = URLRequest(url: feed.url)
        request.timeoutInterval = 30
        request.setValue("Jungle content blocker/1.0", forHTTPHeaderField: "User-Agent")
        if let etag = defaults.string(forKey: etagKey(for: feed.key)) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            if response.statusCode == 304 { return true }
            guard response.statusCode == 200,
                  let filters = String(data: data, encoding: .utf8) else { return false }

            let rules = await Task.detached(priority: .utility) {
                ContentBlockerRuleCompiler.compile(filters)
            }.value
            guard !rules.isEmpty else { return false }
            await compileAndActivate(rules, key: feed.key)
            if let etag = response.value(forHTTPHeaderField: "Etag") {
                defaults.set(etag, forKey: etagKey(for: feed.key))
            }
            return activeLists[feed.key] != nil
        } catch {
            return false
        }
    }

    private func compileAndActivate(_ source: String, key: String) async {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let identifier = "jungle.content.\(key).\(digest.prefix(16))"
        guard let list = await compile(source, identifier: identifier) else { return }

        let oldIdentifier = defaults.string(forKey: identifierKey(for: key))
        activeLists[key] = list
        defaults.set(identifier, forKey: identifierKey(for: key))
        applyActiveLists()

        if let oldIdentifier, oldIdentifier != identifier {
            try? await store?.removeContentRuleList(forIdentifier: oldIdentifier)
        }
    }

    private func applyActiveLists() {
        WebViewPool.shared.applyContentRuleLists(Array(activeLists.values))
    }

    private func lookUp(identifier: String) async -> WKContentRuleList? {
        guard let store else { return nil }
        return await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(_ source: String, identifier: String) async -> WKContentRuleList? {
        guard let store else { return nil }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func identifierKey(for key: String) -> String { "contentBlocking.identifier.\(key)" }
    private func etagKey(for key: String) -> String { "contentBlocking.etag.\(key)" }

    /// A small first-launch shield while the maintained lists download and compile.
    private static let bootstrapDomains = [
        "2mdn.net", "adnxs.com", "adsrvr.org", "amazon-adsystem.com", "analytics.google.com",
        "app-measurement.com", "bat.bing.com", "chartbeat.com", "connect.facebook.net", "demdex.net",
        "doubleclick.net", "googlesyndication.com", "google-analytics.com", "googleadservices.com",
        "googletagmanager.com", "hotjar.com", "imrworldwide.com", "mathtag.com", "mixpanel.com",
        "moatads.com", "mouseflow.com", "nr-data.net", "omtrdc.net", "optimizely.com", "outbrain.com",
        "quantserve.com", "scorecardresearch.com", "segment.io", "segment.com", "sentry.io",
        "taboola.com", "tealiumiq.com", "tiktok.com", "twimg.com", "twitter.com", "zedo.com"
    ]
}

enum ContentBlockerRuleCompiler {
    nonisolated static func compile(_ filters: String, maximumRuleCount: Int = 75_000) -> String {
        guard let hostRule = try? NSRegularExpression(
            pattern: #"^\|\|([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?:\^|\$)"#
        ) else { return "[]" }
        var blockingRules: [ContentBlockerRule] = []
        var exceptionRules: [ContentBlockerRule] = []
        var seenRules = Set<String>()

        filters.enumerateLines { rawLine, stop in
            guard blockingRules.count + exceptionRules.count < maximumRuleCount else {
                stop = true
                return
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.contains("##") else { return }

            let isException = line.hasPrefix("@@")
            let filter = isException ? String(line.dropFirst(2)) : line
            guard let rule = makeRule(from: filter, action: isException ? .ignorePreviousRules : .block, hostRule: hostRule) else { return }
            guard seenRules.insert("\(isException ? "@" : "")\(rule.deduplicationKey)").inserted else { return }
            if isException { exceptionRules.append(rule) } else { blockingRules.append(rule) }
        }

        let rules = blockingRules + exceptionRules
        guard let data = try? JSONEncoder().encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func makeRule(
        from filter: String,
        action: ContentBlockerRule.Action,
        hostRule: NSRegularExpression
    ) -> ContentBlockerRule? {
        let parts = filter.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let pattern = String(parts[0])
        let range = NSRange(pattern.startIndex..., in: pattern)
        guard let match = hostRule.firstMatch(in: pattern, range: range),
              let domainRange = Range(match.range(at: 1), in: pattern) else { return nil }

        let domain = String(pattern[domainRange]).lowercased()
        guard domain.contains("."), !domain.contains("..") else { return nil }
        let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
        // WebKit permits anchors only at the ends of a filter. URLs have a path,
        // query, or port after the host, so an explicit host delimiter remains
        // precise without relying on an unsupported in-expression end anchor.
        let urlFilter = "^https?://([A-Za-z0-9-]+\\.)*\(escapedDomain)[/:?]"
        let modifiers = parts.count == 2 ? parts[1].split(separator: ",").map(String.init) : []
        let trigger = makeTrigger(urlFilter: urlFilter, modifiers: modifiers)
        return ContentBlockerRule(trigger: trigger, action: action)
    }

    nonisolated private static func makeTrigger(urlFilter: String, modifiers: [String]) -> ContentBlockerRule.Trigger {
        let resourceTypes = modifiers.compactMap(resourceType(from:))
        let loadType: [String]?
        if modifiers.contains("third-party") { loadType = ["third-party"] }
        else if modifiers.contains("~third-party") { loadType = ["first-party"] }
        else { loadType = nil }

        let domainModifier = modifiers.first(where: { $0.hasPrefix("domain=") })
        let domains = domainModifier.map { String($0.dropFirst("domain=".count)).split(separator: "|").map(String.init) } ?? []
        let positiveDomains = domains.filter { !$0.hasPrefix("~") }
        let negativeDomains = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }

        return ContentBlockerRule.Trigger(
            urlFilter: urlFilter,
            resourceTypes: resourceTypes.isEmpty ? nil : resourceTypes,
            loadTypes: loadType,
            ifDomains: negativeDomains.isEmpty ? positiveDomains.nilIfEmpty : nil,
            unlessDomains: positiveDomains.isEmpty ? negativeDomains.nilIfEmpty : nil
        )
    }

    nonisolated private static func resourceType(from modifier: String) -> String? {
        switch modifier {
        case "image": "image"
        case "script": "script"
        case "stylesheet": "style-sheet"
        case "font": "font"
        case "media": "media"
        case "popup": "popup"
        case "document", "subdocument": "document"
        case "xmlhttprequest", "ping", "websocket", "other": "raw"
        default: nil
        }
    }
}

nonisolated private struct ContentBlockerRule: Encodable, Sendable {
    struct Trigger: Encodable {
        let urlFilter: String
        let resourceTypes: [String]?
        let loadTypes: [String]?
        let ifDomains: [String]?
        let unlessDomains: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case resourceTypes = "resource-type"
            case loadTypes = "load-type"
            case ifDomains = "if-domain"
            case unlessDomains = "unless-domain"
        }
    }

    struct Action: Encodable {
        enum Kind: String, Encodable {
            case block
            case ignorePreviousRules = "ignore-previous-rules"
        }

        static let block = Action(type: .block)
        static let ignorePreviousRules = Action(type: .ignorePreviousRules)

        let type: Kind
    }

    let trigger: Trigger
    let action: Action

    var deduplicationKey: String { "\(trigger.urlFilter)|\(action.type.rawValue)|\(trigger.loadTypes?.joined(separator: ",") ?? "")" }
}

nonisolated private extension Array where Element == String {
    var nilIfEmpty: [String]? { isEmpty ? nil : self }
}
