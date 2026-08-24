import Foundation
import SwiftData

@Model
final class PersistedBrowserSettings {
    @Attribute(.unique) var id: String
    var searchEngine: String
    var appearance: String
    var tabSleepInterval: TimeInterval
    var activeProfileSlot: Int
    var selectedTabID: UUID?

    init(
        id: String = "current",
        searchEngine: String = BrowserSearchEngine.google.rawValue,
        appearance: String = BrowserAppearance.system.rawValue,
        tabSleepInterval: TimeInterval = 60,
        activeProfileSlot: Int = 0,
        selectedTabID: UUID? = nil
    ) {
        self.id = id
        self.searchEngine = searchEngine
        self.appearance = appearance
        self.tabSleepInterval = tabSleepInterval
        self.activeProfileSlot = activeProfileSlot
        self.selectedTabID = selectedTabID
    }
}

@Model
final class PersistedBookmarkFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortIndex: Int
    var isQuickAccess: Bool
    var isExpanded: Bool

    init(id: UUID, name: String, sortIndex: Int, isQuickAccess: Bool, isExpanded: Bool) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.isQuickAccess = isQuickAccess
        self.isExpanded = isExpanded
    }
}

@Model
final class PersistedBookmark {
    @Attribute(.unique) var id: UUID
    var folderID: UUID
    var title: String
    var address: String
    var symbol: String
    var sortIndex: Int

    init(id: UUID, folderID: UUID, title: String, address: String, symbol: String, sortIndex: Int) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.address = address
        self.symbol = symbol
        self.sortIndex = sortIndex
    }
}

@Model
final class PersistedTab {
    @Attribute(.unique) var id: UUID
    var profileSlot: Int
    var title: String
    var address: String
    var lastActivatedAt: Date
    var isPinned: Bool
    var sortIndex: Int

    init(id: UUID, profileSlot: Int, title: String, address: String, lastActivatedAt: Date, isPinned: Bool, sortIndex: Int) {
        self.id = id
        self.profileSlot = profileSlot
        self.title = title
        self.address = address
        self.lastActivatedAt = lastActivatedAt
        self.isPinned = isPinned
        self.sortIndex = sortIndex
    }
}

@Model
final class PersistedProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var tint: String
    var dataStoreID: UUID
    var sortIndex: Int

    init(id: UUID, name: String, symbol: String, tint: String, dataStoreID: UUID, sortIndex: Int) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.dataStoreID = dataStoreID
        self.sortIndex = sortIndex
    }
}

@MainActor
final class BrowserPersistence {
    static let shared = BrowserPersistence()

    private let context: ModelContext

    private init() {
        let schema = Schema([
            PersistedBrowserSettings.self,
            PersistedBookmarkFolder.self,
            PersistedBookmark.self,
            PersistedTab.self,
            PersistedProfile.self
        ])
        let configuration = ModelConfiguration("Jungle", schema: schema)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            context = ModelContext(container)
        } catch {
            fatalError("Unable to initialize Jungle persistence: \(error.localizedDescription)")
        }
    }

    func loadSettings() -> PersistedBrowserSettings {
        let descriptor = FetchDescriptor<PersistedBrowserSettings>(predicate: #Predicate { $0.id == "current" })
        if let existing = try? context.fetch(descriptor).first { return existing }

        let settings = PersistedBrowserSettings(
            searchEngine: UserDefaults.standard.string(forKey: "jungle.settings.search-engine") ?? BrowserSearchEngine.google.rawValue,
            appearance: UserDefaults.standard.string(forKey: "jungle.settings.appearance") ?? BrowserAppearance.system.rawValue,
            tabSleepInterval: max(UserDefaults.standard.double(forKey: "jungle.settings.tab-sleep-interval"), 60)
        )
        context.insert(settings)
        save()
        return settings
    }

    func saveSettings(searchEngine: BrowserSearchEngine, appearance: BrowserAppearance, tabSleepInterval: TimeInterval) {
        let settings = loadSettings()
        settings.searchEngine = searchEngine.rawValue
        settings.appearance = appearance.rawValue
        settings.tabSleepInterval = tabSleepInterval
        save()
    }

    func loadProfiles() -> [BrowserProfile] {
        let records = (try? context.fetch(FetchDescriptor<PersistedProfile>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        guard !records.isEmpty else {
            let defaults = [
                BrowserProfile(name: "Personal", symbol: "person.crop.circle", tint: .green),
                BrowserProfile(name: "Work", symbol: "briefcase", tint: .orange),
                BrowserProfile(name: "Study", symbol: "book.closed", tint: .blue)
            ]
            saveProfiles(defaults)
            return defaults
        }
        return records.map {
            BrowserProfile(
                id: $0.id,
                name: $0.name,
                symbol: $0.symbol,
                tint: ProfileTint(rawValue: $0.tint) ?? .green,
                dataStoreID: $0.dataStoreID
            )
        }
    }

    func saveProfiles(_ profiles: [BrowserProfile]) {
        let records = (try? context.fetch(FetchDescriptor<PersistedProfile>())) ?? []
        records.forEach(context.delete)
        for (index, profile) in profiles.enumerated() {
            context.insert(PersistedProfile(id: profile.id, name: profile.name, symbol: profile.symbol, tint: profile.tint.rawValue, dataStoreID: profile.dataStoreID, sortIndex: index))
        }
        save()
    }

    func loadBookmarks() -> [BookmarkFolder] {
        let folders = (try? context.fetch(FetchDescriptor<PersistedBookmarkFolder>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        guard !folders.isEmpty else { return migrateOrSeedBookmarks() }
        let bookmarks = (try? context.fetch(FetchDescriptor<PersistedBookmark>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        return folders.map { folder in
            BookmarkFolder(
                id: folder.id,
                name: folder.name,
                bookmarks: bookmarks.compactMap { bookmark in
                    guard bookmark.folderID == folder.id, let address = URL(string: bookmark.address) else { return nil }
                    return BrowserBookmark(id: bookmark.id, title: bookmark.title, address: address, symbol: bookmark.symbol)
                },
                isQuickAccess: folder.isQuickAccess,
                isExpanded: folder.isExpanded
            )
        }
    }

    func saveBookmarks(_ folders: [BookmarkFolder]) {
        let persistedFolders = (try? context.fetch(FetchDescriptor<PersistedBookmarkFolder>())) ?? []
        let persistedBookmarks = (try? context.fetch(FetchDescriptor<PersistedBookmark>())) ?? []
        persistedFolders.forEach(context.delete)
        persistedBookmarks.forEach(context.delete)

        for (folderIndex, folder) in folders.enumerated() {
            context.insert(PersistedBookmarkFolder(id: folder.id, name: folder.name, sortIndex: folderIndex, isQuickAccess: folder.isQuickAccess, isExpanded: folder.isExpanded))
            for (bookmarkIndex, bookmark) in folder.bookmarks.enumerated() {
                context.insert(PersistedBookmark(id: bookmark.id, folderID: folder.id, title: bookmark.title, address: bookmark.address.absoluteString, symbol: bookmark.symbol, sortIndex: bookmarkIndex))
            }
        }
        save()
    }

    func loadWorkspace(profiles: [BrowserProfile]) -> PersistedWorkspace? {
        let settings = loadSettings()
        let records = (try? context.fetch(FetchDescriptor<PersistedTab>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        guard !records.isEmpty else { return nil }
        let tabs = records.compactMap { record -> BrowserTab? in
            guard profiles.indices.contains(record.profileSlot), let address = URL(string: record.address) else { return nil }
            return BrowserTab(id: record.id, profileID: profiles[record.profileSlot].id, address: address, title: record.title, lastActivatedAt: record.lastActivatedAt, isPinned: record.isPinned)
        }
        guard !tabs.isEmpty else { return nil }
        let selectedID = settings.selectedTabID.flatMap { savedID in tabs.contains(where: { $0.id == savedID }) ? savedID : nil } ?? tabs[0].id
        return PersistedWorkspace(tabs: tabs, activeProfileSlot: min(max(settings.activeProfileSlot, 0), profiles.count - 1), selectedTabID: selectedID)
    }

    func saveWorkspace(tabs: [BrowserTab], profiles: [BrowserProfile], activeProfileID: UUID, selectedTabID: UUID?) {
        let records = (try? context.fetch(FetchDescriptor<PersistedTab>())) ?? []
        records.forEach(context.delete)
        for (index, tab) in tabs.enumerated() {
            guard let profileSlot = profiles.firstIndex(where: { $0.id == tab.profileID }) else { continue }
            context.insert(PersistedTab(id: tab.id, profileSlot: profileSlot, title: tab.title, address: tab.address.absoluteString, lastActivatedAt: tab.lastActivatedAt, isPinned: tab.isPinned, sortIndex: index))
        }
        let settings = loadSettings()
        settings.activeProfileSlot = profiles.firstIndex(where: { $0.id == activeProfileID }) ?? 0
        settings.selectedTabID = selectedTabID
        save()
    }

    private func migrateOrSeedBookmarks() -> [BookmarkFolder] {
        if let data = UserDefaults.standard.data(forKey: "jungle.bookmarks"),
           let legacyFolders = try? JSONDecoder().decode([BookmarkFolder].self, from: data),
           !legacyFolders.isEmpty {
            let normalizedFolders = legacyFolders.enumerated().map { index, folder in
                BookmarkFolder(
                    id: folder.id,
                    name: folder.name,
                    bookmarks: folder.bookmarks,
                    isQuickAccess: folder.isQuickAccess || index == 0,
                    isExpanded: folder.isExpanded
                )
            }
            saveBookmarks(normalizedFolders)
            UserDefaults.standard.removeObject(forKey: "jungle.bookmarks")
            return normalizedFolders
        }
        let folders = BookmarkFolder.defaults
        saveBookmarks(folders)
        return folders
    }

    private func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("Unable to save Jungle data: \(error.localizedDescription)")
        }
    }
}

struct PersistedWorkspace {
    let tabs: [BrowserTab]
    let activeProfileSlot: Int
    let selectedTabID: UUID
}
