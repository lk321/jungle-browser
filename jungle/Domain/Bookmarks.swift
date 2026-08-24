import Foundation

struct BrowserBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let address: URL
    let symbol: String

    init(id: UUID = UUID(), title: String, address: URL, symbol: String = "globe") {
        self.id = id
        self.title = title
        self.address = address
        self.symbol = symbol
    }
}

struct BookmarkFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var bookmarks: [BrowserBookmark]
    var isQuickAccess: Bool
    var isExpanded: Bool

    init(id: UUID = UUID(), name: String, bookmarks: [BrowserBookmark] = [], isQuickAccess: Bool = false, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.bookmarks = bookmarks
        self.isQuickAccess = isQuickAccess
        self.isExpanded = isExpanded
    }

    static let defaults = [
        BookmarkFolder(name: "Quick access", bookmarks: [
            BrowserBookmark(title: "Google", address: BrowserAddress.home, symbol: "magnifyingglass"),
            BrowserBookmark(title: "Apple Developer", address: URL(string: "https://developer.apple.com") ?? BrowserAddress.home, symbol: "apple.logo"),
            BrowserBookmark(title: "GitHub", address: URL(string: "https://github.com") ?? BrowserAddress.home, symbol: "chevron.left.forwardslash.chevron.right")
        ], isQuickAccess: true),
        BookmarkFolder(name: "Reading list")
    ]
}
