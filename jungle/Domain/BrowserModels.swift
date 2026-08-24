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

enum BrowserAddress {
    static let home = URL(string: "https://www.google.com") ?? URL(fileURLWithPath: "/")

    static func resolve(_ input: String, using searchEngine: BrowserSearchEngine = .google) -> URL? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if let directURL = URL(string: query), directURL.scheme != nil { return directURL }
        if query.contains("."), !query.contains(" ") { return URL(string: "https://" + query) }

        return searchEngine.searchURL(for: query)
    }
}
