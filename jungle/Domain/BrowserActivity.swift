import Foundation

struct BrowsingHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let profileID: UUID
    let title: String
    let address: URL
    let visitedAt: Date

    init(
        id: UUID = UUID(),
        profileID: UUID,
        title: String,
        address: URL,
        visitedAt: Date = .now
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.address = address
        self.visitedAt = visitedAt
    }
}

enum BrowserDownloadState: String, Equatable {
    case inProgress
    case completed
    case failed

    var title: String {
        switch self {
        case .inProgress: "Downloading"
        case .completed: "Downloaded"
        case .failed: "Interrupted"
        }
    }
}

struct BrowserDownload: Identifiable, Equatable {
    let id: UUID
    let profileID: UUID
    let sourceAddress: URL
    var fileName: String
    var destination: URL?
    let startedAt: Date
    var completedAt: Date?
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var state: BrowserDownloadState
    var failureDescription: String?

    init(
        id: UUID = UUID(),
        profileID: UUID,
        sourceAddress: URL,
        fileName: String,
        destination: URL? = nil,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        state: BrowserDownloadState = .inProgress,
        failureDescription: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.sourceAddress = sourceAddress
        self.fileName = fileName
        self.destination = destination
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.state = state
        self.failureDescription = failureDescription
    }
}
