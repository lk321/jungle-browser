import Combine
import Foundation
import WebKit

/// The find bar of the tab on screen. WebKit does the searching (`PageFinder`); this keeps
/// which match is current, so the count is exact and moving between matches never searches
/// the page again.
@MainActor
final class FindInPage: ObservableObject {
    enum Status: Equatable {
        case idle
        case noMatches
        /// `index` is zero-based. A `count` at `PageFinder.maximumMatches` means at least that many.
        case match(index: Int, count: Int)
        /// The public fallback found something but cannot say where among how many.
        case found
    }

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var isCaseSensitive = false {
        didSet { if isCaseSensitive != oldValue { scheduleSearch() } }
    }
    @Published private(set) var status: Status = .idle
    /// Bumped on every ⌘F, so the field takes focus and selects its text even when already open.
    @Published private(set) var focusRequest = 0

    private(set) var tabID: UUID?
    /// Weak: only `WebViewPool` keeps a web view alive.
    private weak var webView: WKWebView?
    private var matches: [PageFinder.Match] = []
    private var currentIndex: Int?
    private var search: Task<Void, Never>?

    func present(tabID: UUID, webView: WKWebView) {
        focusRequest += 1
        guard !isPresented || self.tabID != tabID || self.webView !== webView else { return }
        dismiss()
        self.tabID = tabID
        self.webView = webView
        isPresented = true
        // The page may have changed since the last search; the text is kept, like Safari.
        if !query.isEmpty { scheduleSearch(after: .zero) }
    }

    func dismiss() {
        search?.cancel()
        if let webView { PageFinder.hide(in: webView) }
        isPresented = false
        tabID = nil
        webView = nil
        matches = []
        currentIndex = nil
        status = .idle
    }

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    /// The page navigated: the old matches point at a document that is gone.
    func pageDidChange(in tabID: UUID) {
        guard isPresented, self.tabID == tabID, !query.isEmpty else { return }
        currentIndex = nil
        scheduleSearch(after: .zero)
    }

    private func move(by offset: Int) {
        guard isPresented, let webView, !query.isEmpty else { return }
        guard PageFinder.canCount(in: webView) else {
            let query = query, caseSensitive = isCaseSensitive
            Task { [weak self] in
                let found = await PageFinder.findNext(query, caseSensitive: caseSensitive, backwards: offset < 0, in: webView)
                self?.status = found ? .found : .noMatches
            }
            return
        }
        guard !matches.isEmpty else { return }
        let index = ((currentIndex ?? -offset) + offset + matches.count) % matches.count
        select(index, in: webView)
    }

    /// A burst of keystrokes becomes one search of the page, not one per character.
    private func scheduleSearch(after delay: Duration = .milliseconds(70)) {
        search?.cancel()
        guard isPresented else { return }
        search = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    private func runSearch() async {
        guard let webView else { return }
        let query = query, caseSensitive = isCaseSensitive
        guard !query.isEmpty else {
            PageFinder.hide(in: webView)
            matches = []
            currentIndex = nil
            status = .idle
            return
        }
        guard PageFinder.canCount(in: webView) else {
            let found = await PageFinder.findNext(query, caseSensitive: caseSensitive, backwards: false, in: webView)
            guard !Task.isCancelled else { return }
            status = found ? .found : .noMatches
            return
        }

        // A search starts where the reader is: at the match already on screen while the text
        // is being typed, or at the top of what is visible for a fresh one.
        let anchor: CGPoint
        if let currentIndex, matches.indices.contains(currentIndex) {
            anchor = matches[currentIndex].origin
        } else {
            anchor = await PageFinder.visibleOrigin(of: webView)
        }
        let found = await PageFinder.matches(of: query, caseSensitive: caseSensitive, in: webView)
        guard !Task.isCancelled else { return }

        matches = found
        guard !found.isEmpty else {
            currentIndex = nil
            status = .noMatches
            return
        }
        select(Self.firstIndex(in: found.map(\.origin), from: anchor), in: webView)
    }

    private func select(_ index: Int, in webView: WKWebView) {
        currentIndex = index
        status = .match(index: index, count: matches.count)
        PageFinder.show(matches[index], in: webView)
    }

    /// The first match at or after `anchor` in reading order, wrapping to the first on the page.
    nonisolated static func firstIndex(in origins: [CGPoint], from anchor: CGPoint) -> Int {
        origins.firstIndex { $0.y > anchor.y || ($0.y == anchor.y && $0.x >= anchor.x) } ?? 0
    }
}
