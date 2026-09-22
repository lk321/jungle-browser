import Foundation
import WebKit

/// Every file transfer the browser runs, for as long as it runs. `WKDownload` holds its delegate
/// weakly and nothing else keeps it alive, so the transfers live here for the session: held by
/// the SwiftUI coordinator, they died whenever SwiftUI dropped the web view, which closing the
/// last tab does. Closing the page a download came from does not stop it — measured.
///
/// A file is written as `Name.ext.download` and only takes its real name once complete, so a
/// half-written disk image never looks like one that opens. The transfer's progress is
/// published on that file, which is what draws Finder's progress bar over its icon and lets
/// Finder cancel it.
@MainActor
final class FileDownloads: NSObject, WKDownloadDelegate {
    static let shared = FileDownloads()

    private final class Transfer {
        let id: UUID
        let store: BrowserStore
        let download: WKDownload
        var destination: URL?
        var finderProgress: Progress?

        init(id: UUID, store: BrowserStore, download: WKDownload) {
            self.id = id
            self.store = store
            self.download = download
        }

        var partial: URL? { destination.map(BrowserDownload.partialDestination(for:)) }
    }

    private var transfers: [ObjectIdentifier: Transfer] = [:]
    /// WebKit reports bytes through `progress` alone: `didReceiveDataOfLength` is not part of
    /// `WKDownloadDelegate` and is never called. Reading it on a timer also paces the store,
    /// whose every write redraws the window.
    private var progressTimer: Timer?

    private override init() {}

    func isRunning(_ downloadID: UUID) -> Bool {
        transfers.values.contains { $0.id == downloadID }
    }

    func track(_ download: WKDownload, store: BrowserStore, tabID: UUID, sourceAddress: URL) {
        let id = store.beginDownload(for: tabID, sourceAddress: sourceAddress)
        transfers[ObjectIdentifier(download)] = Transfer(id: id, store: store, download: download)
        download.delegate = self
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { FileDownloads.shared.reportProgress() }
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let transfer = transfers[ObjectIdentifier(download)] else { return nil }
        guard let destination = transfer.store.prepareDownloadDestination(
            for: transfer.id,
            suggestedFileName: suggestedFilename,
            expectedBytes: response.expectedContentLength
        ) else {
            end(transfer)
            transfer.store.failDownload(transfer.id, errorDescription: "The Downloads folder is not available.")
            return nil
        }
        transfer.destination = destination
        return transfer.partial
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = transfers[ObjectIdentifier(download)] else { return }
        end(transfer)
        guard var destination = transfer.destination, let partial = transfer.partial else { return }
        // Something may have taken the name while the file was on its way.
        if FileManager.default.fileExists(atPath: destination.path),
           let free = transfer.store.prepareDownloadDestination(
               for: transfer.id,
               suggestedFileName: destination.lastPathComponent,
               expectedBytes: nil
           ) {
            destination = free
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
            transfer.store.finishDownload(transfer.id, at: destination)
        } catch {
            // Every byte is there: the file keeps its working name rather than being lost.
            transfer.store.finishDownload(transfer.id, at: partial)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let transfer = transfers[ObjectIdentifier(download)] else { return }
        end(transfer)
        // Nothing resumes a transfer, so the partial file is only clutter in Downloads.
        removePartial(of: transfer)
        transfer.store.failDownload(transfer.id, errorDescription: error.localizedDescription)
    }

    /// Finder's cancel button. `cancel` never calls the delegate and leaves the partial file
    /// behind — measured — so the cleanup happens here, once WebKit has stopped writing.
    private func cancel(_ transfer: Transfer) {
        guard transfers[ObjectIdentifier(transfer.download)] === transfer else { return }
        end(transfer)
        transfer.download.cancel { _ in
            Task { @MainActor in
                FileDownloads.shared.removePartial(of: transfer)
                transfer.store.failDownload(transfer.id, errorDescription: "Cancelled")
            }
        }
    }

    private func reportProgress() {
        transfers.values.forEach(report)
    }

    private func report(_ transfer: Transfer) {
        let (received, expected) = recordProgress(of: transfer)
        // Published once the file exists: WebKit creates it with the first bytes, and it fails
        // a download whose destination is already there.
        guard received > 0, let partial = transfer.partial else { return }
        let finderProgress = transfer.finderProgress ?? publishProgress(of: transfer, at: partial)
        finderProgress.totalUnitCount = expected ?? -1
        finderProgress.completedUnitCount = received
    }

    @discardableResult
    private func recordProgress(of transfer: Transfer) -> (received: Int64, expected: Int64?) {
        let progress = transfer.download.progress
        let received = progress.completedUnitCount
        let expected: Int64? = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
        transfer.store.recordDownloadProgress(receivedBytes: received, expectedBytes: expected, for: transfer.id)
        return (received, expected)
    }

    private func publishProgress(of transfer: Transfer, at partial: URL) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = partial
        progress.isCancellable = true
        progress.cancellationHandler = {
            Task { @MainActor in FileDownloads.shared.cancel(transfer) }
        }
        progress.publish()
        transfer.finderProgress = progress
        return progress
    }

    /// Stops following a transfer. The progress comes off the file before it is renamed, so
    /// Finder never draws a bar over a finished file.
    private func end(_ transfer: Transfer) {
        recordProgress(of: transfer)
        transfer.finderProgress?.unpublish()
        transfer.finderProgress = nil
        transfers.removeValue(forKey: ObjectIdentifier(transfer.download))
        guard transfers.isEmpty else { return }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func removePartial(of transfer: Transfer) {
        guard let partial = transfer.partial else { return }
        try? FileManager.default.removeItem(at: partial)
    }
}
