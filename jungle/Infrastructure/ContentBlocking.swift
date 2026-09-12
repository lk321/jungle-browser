import Combine
import CryptoKit
import Foundation
import WebKit

/// Keeps native WebKit content rules current without putting a per-request
/// interceptor in the browsing path. The public EasyList and EasyPrivacy feeds
/// are parsed into their safe, host-anchored network rules only; unsupported
/// filter syntax is deliberately ignored rather than guessed.
@MainActor
final class ContentBlocking: ObservableObject {
    static let shared = ContentBlocking()

    /// What the settings screen shows about the lists: when they last changed and whether a
    /// check is running right now.
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeRuleListCount = 0

    private struct Feed: Sendable {
        let key: String
        let url: URL
        let maximumRuleCount: Int

        init?(key: String, urlString: String, maximumRuleCount: Int = 75_000) {
            guard let url = URL(string: urlString) else { return nil }
            self.key = key
            self.url = url
            self.maximumRuleCount = maximumRuleCount
        }
    }

    private static let primaryFeeds = [
        Feed(key: "ads", urlString: "https://easylist.to/easylist/easylist.txt"),
        Feed(key: "privacy", urlString: "https://easylist.to/easylist/easyprivacy.txt")
    ].compactMap { $0 }
    private static let fallbackFeed = Feed(
        key: "fallback",
        urlString: "https://cdn.jsdelivr.net/gh/badmojr/1Hosts@master/Lite/adblock.txt",
        maximumRuleCount: 150_000
    )
    private static let maximumPrimaryStaleness: TimeInterval = 60 * 60 * 24 * 7

    /// EasyList is rebuilt several times a day and its server asks for a two-hour cache, so a
    /// daily check left the browser up to a day behind the domains it is meant to block. Six
    /// hours is four conditional requests a day; an unchanged feed answers 304 and costs
    /// nothing beyond the round trip.
    static let refreshInterval: TimeInterval = 60 * 60 * 6

    private let store = WKContentRuleListStore.default()
    private let defaults = UserDefaults.standard
    private var activeLists: [String: WKContentRuleList] = [:]
    private var extensionLists: [String: WKContentRuleList] = [:]
    private var updateTask: Task<Void, Never>?
    private var blocksAdsAndTrackers = true
    private var hidesBlockedAdSpace = true

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
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled else { return }
                await self.refreshIfDue()
            }
        }
    }

    func install(on controller: WKUserContentController) {
        allActiveLists.forEach(controller.add(_:))
    }

    /// Turns the two halves of the blocker on or off. Takes effect on every open tab at once:
    /// WebKit applies content rules per web view, so nothing has to reload.
    func setBlocking(adsAndTrackers: Bool, hidesAdSpace: Bool) {
        guard blocksAdsAndTrackers != adsAndTrackers || hidesBlockedAdSpace != hidesAdSpace else { return }
        blocksAdsAndTrackers = adsAndTrackers
        hidesBlockedAdSpace = hidesAdSpace
        applyActiveLists()
    }

    /// Checks the feeds now, whatever the schedule says.
    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defaults.removeObject(forKey: "contentBlocking.lastRefresh")
        await refreshIfDue()
        isRefreshing = false
    }

    /// Declarative extension rules share the same WebKit content-rule pipeline as
    /// Jungle's built-in blocker. Replacing the whole set prevents stale rules from
    /// surviving after an extension is disabled or removed.
    func setExtensionRuleLists(_ lists: [String: WKContentRuleList]) {
        extensionLists = lists
        applyActiveLists()
    }

    private var allListKeys: [String] {
        let feedKeys = Self.primaryFeeds.map(\.key) + [Self.fallbackFeed?.key].compactMap { $0 }
        return ["bootstrap"] + feedKeys.flatMap { [$0, Self.cosmeticKey(for: $0)] }
    }

    private static func cosmeticKey(for feedKey: String) -> String { "\(feedKey).cosmetic" }

    private func restoreCachedLists() async {
        for key in allListKeys {
            guard let identifier = defaults.string(forKey: identifierKey(for: key)),
                  let list = await lookUp(identifier: identifier) else { continue }
            activeLists[key] = list
        }
        applyActiveLists()
    }

    private func installBootstrapRulesIfNeeded() async {
        guard activeLists["bootstrap"] == nil else { return }
        let ruleSet = ContentBlockerRuleCompiler.compile(
            Self.bootstrapDomains.map { "||\($0)^$third-party" }.joined(separator: "\n"),
            maximumRuleCount: Self.bootstrapDomains.count
        )
        _ = await compileAndActivate(ruleSet.network, key: "bootstrap")
    }

    private func refreshIfDue() async {
        guard shouldRefresh else { return }

        var didRefresh = false
        for feed in Self.primaryFeeds {
            let refreshed = await refresh(feed)
            if refreshed {
                defaults.set(Date.now, forKey: lastSuccessfulRefreshKey(for: feed.key))
                didRefresh = true
            }
        }

        let needsFallback = ContentBlockingSourcePolicy.shouldUseFallback(
            primarySourcesAreUsable: Self.primaryFeeds.map(isUsable(_:))
        )
        if needsFallback, let fallbackFeed = Self.fallbackFeed {
            let refreshed = await refresh(fallbackFeed)
            if refreshed {
                defaults.set(Date.now, forKey: lastSuccessfulRefreshKey(for: fallbackFeed.key))
                didRefresh = true
            }
        } else {
            deactivateList(key: "fallback")
            deactivateList(key: Self.cosmeticKey(for: "fallback"))
        }

        if didRefresh { defaults.set(Date.now, forKey: "contentBlocking.lastRefresh") }
        applyActiveLists()
    }

    private var shouldRefresh: Bool {
        guard Self.primaryFeeds.allSatisfy({ defaults.object(forKey: lastSuccessfulRefreshKey(for: $0.key)) as? Date != nil }) else {
            return true
        }
        guard let date = defaults.object(forKey: "contentBlocking.lastRefresh") as? Date else { return true }
        return Date.now.timeIntervalSince(date) >= Self.refreshInterval
    }

    private func isUsable(_ feed: Feed) -> Bool {
        guard activeLists[feed.key] != nil,
              let date = defaults.object(forKey: lastSuccessfulRefreshKey(for: feed.key)) as? Date else { return false }
        return Date.now.timeIntervalSince(date) <= Self.maximumPrimaryStaleness
    }

    private func refresh(_ feed: Feed) async -> Bool {
        var request = URLRequest(url: feed.url)
        request.timeoutInterval = 30
        request.setValue("Jungle content blocker/1.0", forHTTPHeaderField: "User-Agent")
        // A conditional request is only safe to make while every list it would answer for is
        // actually loaded. Sending the tag with a list missing earns a 304, and a 304 taken as
        // success leaves that list empty until the feed changes upstream — which is how a
        // browser ends up quietly blocking nothing.
        if isFullyLoaded(feed), let etag = defaults.string(forKey: etagKey(for: feed.key)) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            if response.statusCode == 304 { return isFullyLoaded(feed) }
            guard response.statusCode == 200,
                  let filters = String(data: data, encoding: .utf8) else { return false }

            let ruleSet = await Task.detached(priority: .utility) {
                ContentBlockerRuleCompiler.compile(filters, maximumRuleCount: feed.maximumRuleCount)
            }.value
            guard !ruleSet.isEmpty else { return false }

            // Network rules are the feed's reason to exist; element hiding is an improvement
            // on top. A cosmetic list WebKit rejects must not cost the site its network rules.
            guard await compileAndActivate(ruleSet.network, key: feed.key) else { return false }
            let cosmeticKey = Self.cosmeticKey(for: feed.key)
            if ruleSet.cosmetic == "[]" {
                deactivateList(key: cosmeticKey)
                defaults.set(false, forKey: expectsCosmeticKey(for: feed.key))
            } else {
                guard await compileAndActivate(ruleSet.cosmetic, key: cosmeticKey) else { return false }
                defaults.set(true, forKey: expectsCosmeticKey(for: feed.key))
            }

            // Recorded last, so a feed whose rules WebKit refused is fetched again in full
            // next time instead of being answered with a 304 forever.
            if let etag = response.value(forHTTPHeaderField: "Etag") {
                defaults.set(etag, forKey: etagKey(for: feed.key))
            }
            return true
        } catch {
            return false
        }
    }

    /// Compiles one rule list and puts it in front of every tab. Reports whether the list is
    /// live afterwards: an older list left over from a previous launch is not a new one.
    private func compileAndActivate(_ source: String, key: String) async -> Bool {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let identifier = "jungle.content.\(key).\(digest.prefix(16))"
        // Identical rules compile to an identical identifier, so an unchanged feed costs
        // nothing beyond the download: WebKit keeps the compiled bytecode on disk and maps it.
        if defaults.string(forKey: identifierKey(for: key)) == identifier, activeLists[key] != nil { return true }
        guard let list = await compile(source, identifier: identifier) else { return false }

        let oldIdentifier = defaults.string(forKey: identifierKey(for: key))
        activeLists[key] = list
        defaults.set(identifier, forKey: identifierKey(for: key))
        applyActiveLists()

        if let oldIdentifier, oldIdentifier != identifier {
            try? await store?.removeContentRuleList(forIdentifier: oldIdentifier)
        }
        return true
    }

    private func applyActiveLists() {
        let lists = allActiveLists
        activeRuleListCount = lists.count
        lastRefresh = defaults.object(forKey: "contentBlocking.lastRefresh") as? Date
        WebViewPool.shared.applyContentRuleLists(lists)
    }

    /// The lists the user's switches leave standing. Element hiding lives in its own list per
    /// feed, which is what makes it separable from the network rules at all.
    private var allActiveLists: [WKContentRuleList] {
        let enabled = activeLists.filter { key, _ in
            Self.isCosmeticKey(key) ? hidesBlockedAdSpace : blocksAdsAndTrackers
        }
        return Array(enabled.values) + Array(extensionLists.values)
    }

    private static func isCosmeticKey(_ key: String) -> Bool { key.hasSuffix(".cosmetic") }

    private func deactivateList(key: String) {
        guard let list = activeLists.removeValue(forKey: key) else { return }
        defaults.removeObject(forKey: identifierKey(for: key))
        defaults.removeObject(forKey: lastSuccessfulRefreshKey(for: key))
        applyActiveLists()
        store?.removeContentRuleList(forIdentifier: list.identifier) { _ in }
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

    /// Whether every list this feed compiles into is live right now. A feed whose element
    /// hiding failed is not refreshed, however healthy its network rules look.
    private func isFullyLoaded(_ feed: Feed) -> Bool {
        guard activeLists[feed.key] != nil else { return false }
        guard defaults.bool(forKey: expectsCosmeticKey(for: feed.key)) else { return true }
        return activeLists[Self.cosmeticKey(for: feed.key)] != nil
    }

    private func expectsCosmeticKey(for key: String) -> String { "contentBlocking.hasCosmetic.\(key)" }
    private func identifierKey(for key: String) -> String { "contentBlocking.identifier.\(key)" }
    private func etagKey(for key: String) -> String { "contentBlocking.etag.\(key)" }
    private func lastSuccessfulRefreshKey(for key: String) -> String { "contentBlocking.lastSuccessful.\(key)" }

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
