import Foundation

struct BrowserBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let address: URL
    let symbol: String
    /// An SF Symbol the user picked for this saved page. It wins over the site's favicon;
    /// `nil` leaves the favicon in charge. Optional so the legacy JSON still decodes.
    var customSymbol: String?

    init(id: UUID = UUID(), title: String, address: URL, symbol: String = "globe", customSymbol: String? = nil) {
        self.id = id
        self.title = title
        self.address = address
        self.symbol = symbol
        self.customSymbol = customSymbol
    }
}

struct BookmarkFolder: Identifiable, Codable, Hashable {
    let id: UUID
    let profileID: UUID
    var name: String
    var bookmarks: [BrowserBookmark]
    var isQuickAccess: Bool
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        profileID: UUID,
        name: String,
        bookmarks: [BrowserBookmark] = [],
        isQuickAccess: Bool = false,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.bookmarks = bookmarks
        self.isQuickAccess = isQuickAccess
        self.isExpanded = isExpanded
    }

    static func defaults(for profileID: UUID) -> [BookmarkFolder] {
        [
            BookmarkFolder(profileID: profileID, name: "Quick access", bookmarks: [
            BrowserBookmark(title: "Google", address: BrowserAddress.home, symbol: "magnifyingglass"),
            BrowserBookmark(title: "Apple Developer", address: URL(string: "https://developer.apple.com") ?? BrowserAddress.home, symbol: "apple.logo"),
            BrowserBookmark(title: "GitHub", address: URL(string: "https://github.com") ?? BrowserAddress.home, symbol: "chevron.left.forwardslash.chevron.right")
        ], isQuickAccess: true),
            BookmarkFolder(profileID: profileID, name: "Reading list")
        ]
    }
}
