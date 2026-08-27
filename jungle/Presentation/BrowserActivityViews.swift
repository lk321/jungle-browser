import AppKit
import SwiftUI

struct BrowserHistoryView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isClearConfirmationPresented = false

    private var entries: [BrowsingHistoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return store.visibleHistory }
        return store.visibleHistory.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.address.absoluteString.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.primary.opacity(0.08))
            searchField
            content
        }
        .frame(width: 720, height: 640)
        .background(.regularMaterial)
        .alert("Clear history?", isPresented: $isClearConfirmationPresented) {
            Button("Clear history", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes browsing history for the \(store.activeProfile.name) profile.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("\(store.activeProfile.name) profile · \(store.visibleHistory.count) visits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear history", role: .destructive) { isClearConfirmationPresented = true }
                .buttonStyle(.bordered)
                .disabled(store.visibleHistory.isEmpty)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ChromeIconButtonStyle())
                .accessibilityLabel("Close history")
        }
        .padding(20)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search history", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear history search")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            ActivityEmptyState(
                symbol: query.isEmpty ? "clock" : "magnifyingglass",
                title: query.isEmpty ? "No history yet" : "No matching visits",
                message: query.isEmpty ? "Pages you visit in this profile will appear here." : "Try a different title, address, or site name."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry, store: store, dismiss: dismiss)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: BrowsingHistoryEntry
    @ObservedObject var store: BrowserStore
    let dismiss: DismissAction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .background(Color.green.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(entry.address.host ?? entry.address.absoluteString)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Text(entry.visitedAt.formatted(.relative(presentation: .named)))
                .lineLimit(1)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            Button { store.deleteHistoryEntry(entry.id) } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(entry.title) from history")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .interactiveHover(cornerRadius: 11)
        .onTapGesture {
            store.openHistoryEntry(entry)
            dismiss()
        }
        .contextMenu {
            Button("Open in new tab") {
                store.openHistoryEntryInNewTab(entry)
                dismiss()
            }
            Divider()
            Button("Remove from history", role: .destructive) { store.deleteHistoryEntry(entry.id) }
        }
    }
}

struct BrowserDownloadsView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var isClearConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.primary.opacity(0.08))
            content
        }
        .frame(width: 720, height: 640)
        .background(.regularMaterial)
        .alert("Clear download history?", isPresented: $isClearConfirmationPresented) {
            Button("Clear download history", role: .destructive) { store.clearDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the download list for the \(store.activeProfile.name) profile. Downloaded files stay in Finder.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloads")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("\(store.activeProfile.name) profile · saved in Downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear list", role: .destructive) { isClearConfirmationPresented = true }
                .buttonStyle(.bordered)
                .disabled(store.visibleDownloads.isEmpty)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ChromeIconButtonStyle())
                .accessibilityLabel("Close downloads")
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if store.visibleDownloads.isEmpty {
            ActivityEmptyState(
                symbol: "arrow.down.to.line.compact",
                title: "No downloads yet",
                message: "Files you download in this profile will appear here."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.visibleDownloads) { download in
                        DownloadRow(download: download, store: store)
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct DownloadRow: View {
    let download: BrowserDownload
    @ObservedObject var store: BrowserStore

    private var progress: Double? {
        guard let expectedBytes = download.expectedBytes, expectedBytes > 0 else { return nil }
        return min(Double(download.receivedBytes) / Double(expectedBytes), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: download.state == .completed ? "doc.fill" : "arrow.down.doc.fill")
                .foregroundStyle(download.state == .failed ? .red : .green)
                .frame(width: 38, height: 38)
                .background((download.state == .failed ? Color.red : Color.green).opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(download.fileName)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Text(download.state.title)
                    if download.state == .inProgress {
                        Text(byteProgress)
                    } else if let completedAt = download.completedAt {
                        Text(completedAt.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(download.state == .failed ? .red : .secondary)
                if download.state == .inProgress, let progress {
                    ProgressView(value: progress)
                        .tint(.green)
                        .frame(maxWidth: .infinity)
                } else if let failureDescription = download.failureDescription {
                    Text(failureDescription)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            Spacer(minLength: 8)
            if download.state == .completed, let destination = download.destination {
                Button { NSWorkspace.shared.open(destination) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Open file")
                Button { NSWorkspace.shared.activateFileViewerSelecting([destination]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Show in Finder")
            }
            Button { store.deleteDownload(download.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Remove from download history")
            .accessibilityLabel("Remove \(download.fileName) from download history")
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06)))
    }

    private var byteProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let expectedBytes = download.expectedBytes {
            return "· \(formatter.string(fromByteCount: download.receivedBytes)) of \(formatter.string(fromByteCount: expectedBytes))"
        }
        return "· \(formatter.string(fromByteCount: download.receivedBytes))"
    }
}

private struct ActivityEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: 68, height: 68)
                .background(Color.green.opacity(0.11), in: Circle())
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
            Text(message)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
