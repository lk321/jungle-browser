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
        case history

        var symbol: String {
            switch self {
            case .tab: "rectangle.on.rectangle"
            case .bookmark: "bookmark.fill"
            case .history: "clock.arrow.circlepath"
            }
        }

        var label: String {
            switch self {
            case .tab: "Open tab"
            case .bookmark: "Saved page"
            case .history: "Visited"
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

    /// Schemes WebKit loads itself, on top of the app's own `jungle:` pages.
    private static let schemesWebKitLoads: Set<String> = [
        "http", "https", "about", "blob", "data", "file", "javascript", "ws", "wss"
    ]

    /// Whether an address belongs to another app: `mailto:`, `zoommtg:`, the `claude:` link a
    /// sign-in page sends back. WebKit drops these without a word, so they have to be handed
    /// over to whichever app registered the scheme.
    static func opensInAnotherApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !schemesWebKitLoads.contains(scheme) && scheme != nativeNewTab.scheme?.lowercased()
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

/// A framework or library observed in the live page, paired with the signal that revealed
/// it: the toolbar shows the reason so a detection is never mistaken for a guess.
struct DetectedTechnology: Equatable {
    let name: String
    let detail: String
}

struct DeveloperMetrics: Equatable {
    let pageURL: URL
    let requestCount: Int
    let repeatedRequestCount: Int
    let transferredBytes: Int64
    let javaScriptHeapBytes: Int64?
    let documentNodeCount: Int
    let loadDurationMilliseconds: Int?
    let technologies: [DetectedTechnology]

    static let empty = DeveloperMetrics(
        pageURL: BrowserAddress.home,
        requestCount: 0,
        repeatedRequestCount: 0,
        transferredBytes: 0,
        javaScriptHeapBytes: nil,
        documentNodeCount: 0,
        loadDurationMilliseconds: nil,
        technologies: []
    )
}

/// What a tab puts on screen after a load fails. WebKit paints nothing at all when it cannot
/// reach a site, so without this the tab is a blank rectangle with no way back.
struct NavigationFailure: Equatable {
    let address: URL
    let symbol: String
    let title: String
    let message: String

    /// `nil` for the errors that are not failures: a load something cancelled, and the two
    /// policy changes WebKit reports when a response turns into a download or is ignored.
    init?(error: Error, address: URL) {
        let error = error as NSError
        let isCancellation = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204))
        guard !isCancellation else { return nil }

        self.address = address
        let host = address.host ?? address.absoluteString
        // Codes are only meaningful inside their own domain; 0 is no URL error, so anything
        // WebKit or a plugin raises lands on the general case with its own description.
        switch error.domain == NSURLErrorDomain ? error.code : 0 {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            symbol = "questionmark.circle"
            title = "Site not found"
            message = "Jungle can't find a server at \(host). Check the address for a typo."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            symbol = "wifi.slash"
            title = "You're offline"
            message = "This Mac lost its internet connection, so \(host) is out of reach."
        case NSURLErrorCannotConnectToHost:
            symbol = "bolt.horizontal.circle"
            title = "Can't connect"
            message = "\(host) refused the connection. The server may be down or the port closed."
        case NSURLErrorTimedOut:
            symbol = "clock.badge.exclamationmark"
            title = "The server took too long"
            message = "\(host) didn't answer in time."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            symbol = "lock.trianglebadge.exclamationmark"
            title = "The connection isn't private"
            message = "Jungle couldn't verify the certificate \(host) presented."
        default:
            symbol = "exclamationmark.triangle"
            title = "This page didn't load"
            message = error.localizedDescription
        }
    }
}
