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

@MainActor
final class BrowserSettings: ObservableObject {
    @Published var searchEngine: BrowserSearchEngine { didSet { save() } }
    @Published var newTabDestination: BrowserNewTabDestination { didSet { save() } }
    @Published var customNewTabAddress: String { didSet { save() } }
    @Published var appearance: BrowserAppearance { didSet { save() } }
    @Published var tabSleepInterval: TimeInterval { didSet { save() } }
    private let persistence: BrowserPersistence

    init(persistence: BrowserPersistence? = nil) {
        let resolvedPersistence = persistence ?? BrowserPersistence.shared
        self.persistence = resolvedPersistence
        let saved = resolvedPersistence.loadSettings()
        searchEngine = BrowserSearchEngine(rawValue: saved.searchEngine) ?? .google
        newTabDestination = BrowserNewTabDestination(rawValue: saved.newTabDestination ?? "") ?? .searchEngine
        customNewTabAddress = saved.customNewTabAddress ?? ""
        appearance = BrowserAppearance(rawValue: saved.appearance) ?? .system
        tabSleepInterval = saved.tabSleepInterval > 0 ? saved.tabSleepInterval : 60
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
            tabSleepInterval: tabSleepInterval
        )
    }
}
