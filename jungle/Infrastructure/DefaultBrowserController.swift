import AppKit
import Combine
import Foundation

@MainActor
final class DefaultBrowserController: ObservableObject {
    @Published private(set) var isDefaultBrowser = false
    @Published private(set) var isUpdating = false
    @Published private(set) var failureDescription: String?

    private let schemes = ["http", "https"]

    func refresh() {
        let applicationURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        isDefaultBrowser = schemes.allSatisfy { scheme in
            guard let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: sampleURL(for: scheme)) else { return false }
            return handlerURL.resolvingSymlinksInPath().standardizedFileURL == applicationURL
        }
    }

    func makeDefaultBrowser() {
        guard !isUpdating else { return }
        isUpdating = true
        failureDescription = nil
        let applicationURL = Bundle.main.bundleURL

        Task { [weak self] in
            guard let self else { return }
            defer { isUpdating = false }
            do {
                for scheme in schemes {
                    try await NSWorkspace.shared.setDefaultApplication(
                        at: applicationURL,
                        toOpenURLsWithScheme: scheme
                    )
                }
                refresh()
            } catch {
                failureDescription = error.localizedDescription
                refresh()
            }
        }
    }

    private func sampleURL(for scheme: String) -> URL {
        URL(string: "\(scheme)://jungle.local") ?? BrowserAddress.home
    }
}
