import AppKit
import Foundation

enum ProfileTint: String, CaseIterable, Codable, Hashable {
    case green
    case orange
    case blue
    case purple

    var color: NSColor {
        switch self {
        case .green: .systemGreen
        case .orange: .systemOrange
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }
}

struct BrowserProfile: Identifiable, Hashable {
    let id: UUID
    let name: String
    let symbol: String
    let tint: ProfileTint
    let dataStoreID: UUID

    init(id: UUID = UUID(), name: String, symbol: String, tint: ProfileTint, dataStoreID: UUID = UUID()) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.dataStoreID = dataStoreID
    }
}

struct BrowserTab: Identifiable, Equatable {
    let id: UUID
    let profileID: UUID
    var title: String
    var address: URL
    var lastActivatedAt: Date
    var isPinned: Bool
    var isSuspended: Bool
    var preview: NSImage?

    init(id: UUID = UUID(), profileID: UUID, address: URL = BrowserAddress.home, title: String = "New Tab", lastActivatedAt: Date = .now, isPinned: Bool = false) {
        self.id = id
        self.profileID = profileID
        self.address = address
        self.title = title
        self.lastActivatedAt = lastActivatedAt
        self.isPinned = isPinned
        isSuspended = false
        preview = nil
    }
}

/// A Chrome Manifest V3 package whose static network rules have been translated to
/// WebKit content rules. It deliberately has no JavaScript execution surface.
struct BrowserExtension: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let version: String
    let ruleCount: Int
    let unsupportedRuleCount: Int
    let ruleListIdentifier: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        version: String,
        ruleCount: Int,
        unsupportedRuleCount: Int,
        ruleListIdentifier: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.ruleCount = ruleCount
        self.unsupportedRuleCount = unsupportedRuleCount
        self.ruleListIdentifier = ruleListIdentifier
        self.isEnabled = isEnabled
    }
}

struct AddressSuggestion: Identifiable, Hashable {
    let title: String
    let address: URL
    let source: Source

    var id: URL { address }

    enum Source: Hashable {
        case tab
        case bookmark

        var symbol: String {
            switch self {
            case .tab: "rectangle.on.rectangle"
            case .bookmark: "bookmark.fill"
            }
        }

        var label: String {
            switch self {
            case .tab: "Open tab"
            case .bookmark: "Saved page"
            }
        }
    }
}

enum SmartAddressSuggestion: Identifiable {
    case direct(URL)
    case search(query: String, engine: BrowserSearchEngine)
    case saved(AddressSuggestion)

    var id: String {
        switch self {
        case let .direct(url): "direct-\(url.absoluteString)"
        case let .search(query, engine): "search-\(engine.rawValue)-\(query)"
        case let .saved(suggestion): "saved-\(suggestion.id.absoluteString)"
        }
    }

    var input: String {
        switch self {
        case let .direct(url): url.absoluteString
        case let .search(query, _): query
        case let .saved(suggestion): suggestion.address.absoluteString
        }
    }

    var symbol: String {
        switch self {
        case .direct: "link"
        case .search: "magnifyingglass"
        case let .saved(suggestion): suggestion.source.symbol
        }
    }

    var title: String {
        switch self {
        case let .direct(url): "Open \(url.host ?? url.absoluteString)"
        case let .search(query, _): "Search “\(query)”"
        case let .saved(suggestion): suggestion.title
        }
    }

    var detail: String {
        switch self {
        case let .direct(url): url.absoluteString
        case let .search(_, engine): "Search with \(engine.title)"
        case let .saved(suggestion): suggestion.address.absoluteString
        }
    }

    var sourceLabel: String? {
        guard case let .saved(suggestion) = self else { return nil }
        return suggestion.source.label
    }

    var accessibilityLabel: String { "\(title), \(detail)" }
}

enum BrowserAddress {
    static let home = URL(string: "https://www.google.com") ?? URL(fileURLWithPath: "/")
    static let nativeNewTab = URL(string: "jungle://new-tab") ?? URL(fileURLWithPath: "/")

    static func isNativeNewTab(_ url: URL) -> Bool {
        url == nativeNewTab
    }

    static func isWebURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": true
        default: false
        }
    }

    static func usesInsecureHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
    }

    static func isLocalDevelopmentURL(_ url: URL) -> Bool {
        switch url.host?.lowercased() {
        case "localhost", "127.0.0.1": true
        default: false
        }
    }

    static func directWebURL(from input: String) -> URL? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if let url = URL(string: address), url.scheme != nil {
            return isWebURL(url) ? url : nil
        }
        guard address.contains("."), !address.contains(" "), let url = URL(string: "https://\(address)") else { return nil }
        return isWebURL(url) ? url : nil
    }

    static func resolve(_ input: String, using searchEngine: BrowserSearchEngine = .google) -> URL? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if let directURL = directWebURL(from: query) { return directURL }

        return searchEngine.searchURL(for: query)
    }
}

extension BrowserTab {
    var isNativeNewTab: Bool { BrowserAddress.isNativeNewTab(address) }
}

struct DeveloperMetrics: Equatable {
    let pageURL: URL
    let requestCount: Int
    let repeatedRequestCount: Int
    let transferredBytes: Int64
    let javaScriptHeapBytes: Int64?
    let documentNodeCount: Int
    let loadDurationMilliseconds: Int?

    static let empty = DeveloperMetrics(
        pageURL: BrowserAddress.home,
        requestCount: 0,
        repeatedRequestCount: 0,
        transferredBytes: 0,
        javaScriptHeapBytes: nil,
        documentNodeCount: 0,
        loadDurationMilliseconds: nil
    )
}
