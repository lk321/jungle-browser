import Foundation
import SwiftData

@Model
final class PersistedBrowserSettings {
    @Attribute(.unique) var id: String
    var searchEngine: String
    var newTabDestination: String?
    var customNewTabAddress: String?
    var appearance: String
    var tabSleepInterval: TimeInterval
    var activeProfileSlot: Int
    var selectedTabID: UUID?

    init(
        id: String = "current",
        searchEngine: String = BrowserSearchEngine.google.rawValue,
        newTabDestination: String? = nil,
        customNewTabAddress: String? = nil,
        appearance: String = BrowserAppearance.system.rawValue,
        tabSleepInterval: TimeInterval = 60,
        activeProfileSlot: Int = 0,
        selectedTabID: UUID? = nil
    ) {
        self.id = id
        self.searchEngine = searchEngine
        self.newTabDestination = newTabDestination
        self.customNewTabAddress = customNewTabAddress
        self.appearance = appearance
        self.tabSleepInterval = tabSleepInterval
        self.activeProfileSlot = activeProfileSlot
        self.selectedTabID = selectedTabID
    }
}

@Model
final class PersistedBookmarkFolder {
    @Attribute(.unique) var id: UUID
    var profileID: UUID?
    var name: String
    var sortIndex: Int
    var isQuickAccess: Bool
    var isExpanded: Bool

    init(id: UUID, profileID: UUID, name: String, sortIndex: Int, isQuickAccess: Bool, isExpanded: Bool) {
        self.id = id
        self.profileID = profileID
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

@Model
final class PersistedHistoryEntry {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var title: String
    var address: String
    var visitedAt: Date

    init(id: UUID, profileID: UUID, title: String, address: String, visitedAt: Date) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.address = address
        self.visitedAt = visitedAt
    }
}

@Model
final class PersistedDownload {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var sourceAddress: String
    var fileName: String
    var destinationPath: String?
    var startedAt: Date
    var completedAt: Date?
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var state: String
    var failureDescription: String?

    init(
        id: UUID,
        profileID: UUID,
        sourceAddress: String,
        fileName: String,
        destinationPath: String?,
        startedAt: Date,
        completedAt: Date?,
        receivedBytes: Int64,
        expectedBytes: Int64?,
        state: String,
        failureDescription: String?
    ) {
        self.id = id
        self.profileID = profileID
        self.sourceAddress = sourceAddress
        self.fileName = fileName
        self.destinationPath = destinationPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.state = state
        self.failureDescription = failureDescription
    }
}

@MainActor
final class BrowserPersistence {
    static let shared = BrowserPersistence()

    private let context: ModelContext

    private init() {
        let schema = Self.schema
        let configuration = ModelConfiguration("Jungle", schema: schema)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            context = ModelContext(container)
        } catch {
            fatalError("Unable to initialize Jungle persistence: \(error.localizedDescription)")
        }
    }

    init(testingInMemory: Bool) throws {
        precondition(testingInMemory)
        let schema = Self.schema
        let configuration = ModelConfiguration("JungleTests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    private static var schema: Schema {
        Schema([
            PersistedBrowserSettings.self,
            PersistedBookmarkFolder.self,
            PersistedBookmark.self,
            PersistedTab.self,
            PersistedProfile.self,
            PersistedHistoryEntry.self,
            PersistedDownload.self
        ])
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

    func saveSettings(
        searchEngine: BrowserSearchEngine,
        newTabDestination: BrowserNewTabDestination,
        customNewTabAddress: String,
        appearance: BrowserAppearance,
        tabSleepInterval: TimeInterval
    ) {
        let settings = loadSettings()
        settings.searchEngine = searchEngine.rawValue
        settings.newTabDestination = newTabDestination.rawValue
        settings.customNewTabAddress = customNewTabAddress
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

    func loadBookmarks(for profiles: [BrowserProfile]) -> [BookmarkFolder] {
        guard let fallbackProfileID = profiles.first?.id else { return [] }
        let folders = (try? context.fetch(FetchDescriptor<PersistedBookmarkFolder>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        guard !folders.isEmpty else {
            if let data = UserDefaults.standard.data(forKey: "jungle.bookmarks"),
               let legacyFolders = try? JSONDecoder().decode([LegacyBookmarkFolder].self, from: data),
               !legacyFolders.isEmpty {
                let migratedFolders = legacyFolders.enumerated().map { index, folder in
                    BookmarkFolder(
                        id: folder.id,
                        profileID: fallbackProfileID,
                        name: folder.name,
                        bookmarks: folder.bookmarks,
                        isQuickAccess: folder.isQuickAccess || index == 0,
                        isExpanded: folder.isExpanded
                    )
                }
                let missingProfileFolders = profiles.dropFirst().flatMap { BookmarkFolder.defaults(for: $0.id) }
                let normalizedFolders = migratedFolders + missingProfileFolders
                saveBookmarks(normalizedFolders)
                UserDefaults.standard.removeObject(forKey: "jungle.bookmarks")
                return normalizedFolders
            }
            let defaults = profiles.flatMap { BookmarkFolder.defaults(for: $0.id) }
            saveBookmarks(defaults)
            return defaults
        }
        let bookmarks = (try? context.fetch(FetchDescriptor<PersistedBookmark>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let profileIDs = Set(profiles.map(\.id))
        var requiresMigration = false
        var loadedFolders = folders.compactMap { folder -> BookmarkFolder? in
            let profileID = folder.profileID.flatMap { profileIDs.contains($0) ? $0 : nil } ?? fallbackProfileID
            requiresMigration = requiresMigration || folder.profileID != profileID
            return BookmarkFolder(
                id: folder.id,
                profileID: profileID,
                name: folder.name,
                bookmarks: bookmarks.compactMap { bookmark in
                    guard bookmark.folderID == folder.id, let address = URL(string: bookmark.address) else { return nil }
                    return BrowserBookmark(id: bookmark.id, title: bookmark.title, address: address, symbol: bookmark.symbol)
                },
                isQuickAccess: folder.isQuickAccess,
                isExpanded: folder.isExpanded
            )
        }
        for profile in profiles where !loadedFolders.contains(where: { $0.profileID == profile.id }) {
            loadedFolders.append(contentsOf: BookmarkFolder.defaults(for: profile.id))
            requiresMigration = true
        }
        if requiresMigration {
            saveBookmarks(loadedFolders)
        }
        return loadedFolders
    }

    func saveBookmarks(_ folders: [BookmarkFolder]) {
        let persistedFolders = (try? context.fetch(FetchDescriptor<PersistedBookmarkFolder>())) ?? []
        let persistedBookmarks = (try? context.fetch(FetchDescriptor<PersistedBookmark>())) ?? []
        persistedFolders.forEach(context.delete)
        persistedBookmarks.forEach(context.delete)

        for (folderIndex, folder) in folders.enumerated() {
            context.insert(PersistedBookmarkFolder(id: folder.id, profileID: folder.profileID, name: folder.name, sortIndex: folderIndex, isQuickAccess: folder.isQuickAccess, isExpanded: folder.isExpanded))
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

    func loadHistory() -> [BrowsingHistoryEntry] {
        var descriptor = FetchDescriptor<PersistedHistoryEntry>(sortBy: [SortDescriptor(\.visitedAt, order: .reverse)])
        // Older entries stay on disk; keeping every visit ever in memory is what grows unbounded.
        descriptor.fetchLimit = BrowserStore.retainedHistoryCount
        let records = (try? context.fetch(descriptor)) ?? []
        return records.compactMap { record in
            guard let address = URL(string: record.address) else { return nil }
            return BrowsingHistoryEntry(
                id: record.id,
                profileID: record.profileID,
                title: record.title,
                address: address,
                visitedAt: record.visitedAt
            )
        }
    }

    func saveHistoryEntry(_ entry: BrowsingHistoryEntry) {
        context.insert(
            PersistedHistoryEntry(
                id: entry.id,
                profileID: entry.profileID,
                title: entry.title,
                address: entry.address.absoluteString,
                visitedAt: entry.visitedAt
            )
        )
        save()
    }

    func deleteHistoryEntry(_ entryID: UUID) {
        let descriptor = FetchDescriptor<PersistedHistoryEntry>(predicate: #Predicate { $0.id == entryID })
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        save()
    }

    func deleteHistory(for profileID: UUID) {
        let descriptor = FetchDescriptor<PersistedHistoryEntry>(predicate: #Predicate { $0.profileID == profileID })
        let records = (try? context.fetch(descriptor)) ?? []
        records.forEach(context.delete)
        save()
    }

    func loadDownloads() -> [BrowserDownload] {
        let records = (try? context.fetch(FetchDescriptor<PersistedDownload>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
        return records.compactMap { record in
            guard let sourceAddress = URL(string: record.sourceAddress) else { return nil }
            return BrowserDownload(
                id: record.id,
                profileID: record.profileID,
                sourceAddress: sourceAddress,
                fileName: record.fileName,
                destination: record.destinationPath.map(URL.init(fileURLWithPath:)),
                startedAt: record.startedAt,
                completedAt: record.completedAt,
                receivedBytes: record.receivedBytes,
                expectedBytes: record.expectedBytes,
                state: BrowserDownloadState(rawValue: record.state) ?? .failed,
                failureDescription: record.failureDescription
            )
        }
    }

    func saveDownload(_ download: BrowserDownload) {
        let downloadID = download.id
        let descriptor = FetchDescriptor<PersistedDownload>(predicate: #Predicate { $0.id == downloadID })
        let record = (try? context.fetch(descriptor).first) ?? PersistedDownload(
            id: download.id,
            profileID: download.profileID,
            sourceAddress: download.sourceAddress.absoluteString,
            fileName: download.fileName,
            destinationPath: download.destination?.path,
            startedAt: download.startedAt,
            completedAt: download.completedAt,
            receivedBytes: download.receivedBytes,
            expectedBytes: download.expectedBytes,
            state: download.state.rawValue,
            failureDescription: download.failureDescription
        )
        if record.modelContext == nil { context.insert(record) }
        record.profileID = download.profileID
        record.sourceAddress = download.sourceAddress.absoluteString
        record.fileName = download.fileName
        record.destinationPath = download.destination?.path
        record.startedAt = download.startedAt
        record.completedAt = download.completedAt
        record.receivedBytes = download.receivedBytes
        record.expectedBytes = download.expectedBytes
        record.state = download.state.rawValue
        record.failureDescription = download.failureDescription
        save()
    }

    func deleteDownload(_ downloadID: UUID) {
        let descriptor = FetchDescriptor<PersistedDownload>(predicate: #Predicate { $0.id == downloadID })
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        save()
    }

    func deleteDownloads(for profileID: UUID) {
        let descriptor = FetchDescriptor<PersistedDownload>(predicate: #Predicate { $0.profileID == profileID })
        let records = (try? context.fetch(descriptor)) ?? []
        records.forEach(context.delete)
        save()
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

private struct LegacyBookmarkFolder: Codable {
    let id: UUID
    let name: String
    let bookmarks: [BrowserBookmark]
    let isQuickAccess: Bool
    let isExpanded: Bool
}
