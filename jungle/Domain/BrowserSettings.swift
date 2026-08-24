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
}

@MainActor
final class BrowserSettings: ObservableObject {
    @Published var searchEngine: BrowserSearchEngine { didSet { save() } }
    @Published var appearance: BrowserAppearance { didSet { save() } }
    @Published var tabSleepInterval: TimeInterval { didSet { save() } }
    private let persistence: BrowserPersistence

    init(persistence: BrowserPersistence? = nil) {
        let resolvedPersistence = persistence ?? BrowserPersistence.shared
        self.persistence = resolvedPersistence
        let saved = resolvedPersistence.loadSettings()
        searchEngine = BrowserSearchEngine(rawValue: saved.searchEngine) ?? .google
        appearance = BrowserAppearance(rawValue: saved.appearance) ?? .system
        tabSleepInterval = saved.tabSleepInterval > 0 ? saved.tabSleepInterval : 60
    }

    private func save() {
        persistence.saveSettings(searchEngine: searchEngine, appearance: appearance, tabSleepInterval: tabSleepInterval)
    }
}
