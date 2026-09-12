import Foundation
import SwiftUI
import Combine

enum BrowserSearchEngine: String, CaseIterable, Codable, Identifiable {
    case google
    case duckDuckGo
    case brave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        }
    }

    var homeURL: URL {
        switch self {
        case .google: requiredURL("https://www.google.com")
        case .duckDuckGo: requiredURL("https://duckduckgo.com")
        case .brave: requiredURL("https://search.brave.com")
        }
    }

    func searchURL(for query: String) -> URL? {
        switch self {
        case .google:
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            return components?.url
        case .duckDuckGo:
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            return components?.url
        case .brave:
            var components = URLComponents(string: "https://search.brave.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            return components?.url
        }
    }
}

enum BrowserNewTabDestination: String, CaseIterable, Codable, Identifiable {
    case native
    case searchEngine
    case youtube
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: "Jungle new tab"
        case .searchEngine: "Search engine"
        case .youtube: "YouTube"
        case .custom: "Custom website"
        }
    }

    var symbol: String {
        switch self {
        case .native: "leaf.fill"
        case .searchEngine: "magnifyingglass"
        case .youtube: "play.rectangle.fill"
        case .custom: "link"
        }
    }

    func url(searchEngine: BrowserSearchEngine, customAddress: String) -> URL {
        switch self {
        case .native:
            BrowserAddress.nativeNewTab
        case .searchEngine:
            searchEngine.homeURL
        case .youtube:
            requiredURL("https://www.youtube.com")
        case .custom:
            Self.webURL(from: customAddress) ?? searchEngine.homeURL
        }
    }

    private static func webURL(from input: String) -> URL? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        let suppliedURL = URL(string: address)
        let url = suppliedURL?.scheme == nil ? URL(string: "https://\(address)") : suppliedURL
        guard let url, BrowserAddress.isWebURL(url) else { return nil }
        return url
    }
}

private func requiredURL(_ value: String) -> URL {
    guard let url = URL(string: value) else { preconditionFailure("Invalid built-in URL: \(value)") }
    return url
}

enum BrowserAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func usesDarkContent(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }
}

/// What the blocker is allowed to do. One value, so a change to any part of it reaches the
/// browser as a single update instead of five separate ones.
struct AdBlockingOptions: Equatable, Sendable {
    /// The filter lists themselves: the ad and tracker requests never leave the machine.
    var blocksAdsAndTrackers = true
    /// Element hiding, which closes the empty frame an ad left behind. Kept separate because
    /// it is the part that can take a piece of a page with it.
    var hidesBlockedAdSpace = true
    /// Answers the pages that refuse to work until the blocker is off.
    var bypassesAdblockWalls = true
    /// A window an embedded player asks for is the ad, not the video.
    var blocksEmbeddedPlayerPopups = true
    /// Skips the ads inside a YouTube video, which no network list can reach.
    var skipsYouTubeAds = true
}

@MainActor
final class BrowserSettings: ObservableObject {
    @Published var searchEngine: BrowserSearchEngine { didSet { save() } }
    @Published var newTabDestination: BrowserNewTabDestination { didSet { save() } }
    @Published var customNewTabAddress: String { didSet { save() } }
    @Published var appearance: BrowserAppearance { didSet { save() } }
    @Published var tabSleepInterval: TimeInterval { didSet { save() } }
    @Published var sidebarWidth: CGFloat { didSet { save() } }
    @Published var adBlocking: AdBlockingOptions { didSet { save() } }
    private let persistence: BrowserPersistence

    /// How long a tab may sit untouched before its web process is released. One minute meant a
    /// tab you looked away from came back as a cold network load; five is still bounded but
    /// survives an ordinary detour. The Memory setting overrides it in either direction.
    nonisolated static let defaultTabSleepInterval: TimeInterval = 300

    init(persistence: BrowserPersistence? = nil) {
        let resolvedPersistence = persistence ?? BrowserPersistence.shared
        self.persistence = resolvedPersistence
        let saved = resolvedPersistence.loadSettings()
        searchEngine = BrowserSearchEngine(rawValue: saved.searchEngine) ?? .google
        newTabDestination = BrowserNewTabDestination(rawValue: saved.newTabDestination ?? "") ?? .searchEngine
        customNewTabAddress = saved.customNewTabAddress ?? ""
        appearance = BrowserAppearance(rawValue: saved.appearance) ?? .system
        tabSleepInterval = saved.tabSleepInterval > 0 ? saved.tabSleepInterval : Self.defaultTabSleepInterval
        // Anything the store hands back is snapped: a width between steps would leave the
        // sidebar in a layout no step describes.
        sidebarWidth = SidebarStep.nearest(to: saved.sidebarWidth.map { CGFloat($0) } ?? SidebarStep.full.width).width
        // A stored blocker preference is a switch the user turned off. Anything never written
        // stays on, so an existing install keeps the protection it already had.
        adBlocking = AdBlockingOptions(
            blocksAdsAndTrackers: saved.blocksAdsAndTrackers ?? true,
            hidesBlockedAdSpace: saved.hidesBlockedAdSpace ?? true,
            bypassesAdblockWalls: saved.bypassesAdblockWalls ?? true,
            blocksEmbeddedPlayerPopups: saved.blocksEmbeddedPlayerPopups ?? true,
            skipsYouTubeAds: saved.skipsYouTubeAds ?? true
        )
    }

    var newTabURL: URL {
        newTabDestination.url(searchEngine: searchEngine, customAddress: customNewTabAddress)
    }

    private func save() {
        persistence.saveSettings(
            searchEngine: searchEngine,
            newTabDestination: newTabDestination,
            customNewTabAddress: customNewTabAddress,
            appearance: appearance,
            tabSleepInterval: tabSleepInterval,
            sidebarWidth: sidebarWidth,
            adBlocking: adBlocking
        )
    }
}
