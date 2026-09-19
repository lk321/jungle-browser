import AppKit
import WebKit

/// Find in page through WebKit's own engine, the one Safari's find bar drives. It searches
/// every frame in native code, dims the page around every match and bounces the current one;
/// a script walking the DOM would stall a large page on every keystroke and could not see into
/// a cross-origin frame at all.
///
/// The calls are WebKit's `NSTextFinder` document API, which WKWebView keeps private. Every
/// selector is checked before it is sent, and without them the public `find` still moves from
/// match to match — it just cannot count them.
///
/// ponytail: `_findString:options:maxCount:` is the simpler call, but the match index it
/// reports is a running counter that restarts at 0 whenever the text changes, wherever the
/// match actually is. Collecting the matches once and selecting them by position is what makes
/// "3 of 27" true, and what lets next and previous skip searching the page again.
@MainActor
enum PageFinder {
    /// WebKit stops collecting here, so a count this high means "at least".
    static let maximumMatches = 1000

    struct Match {
        /// WebKit's own match object, handed back to select it.
        fileprivate let token: NSObject
        /// Where the match starts on the page, in document coordinates.
        let origin: CGPoint
    }

    private static let collectSelector = NSSelectorFromString("findMatchesForString:relativeToMatch:findOptions:maxResults:resultCollector:")
    private static let platformUISelector = NSSelectorFromString("_setUsePlatformFindUI:")
    private static let selectSelector = NSSelectorFromString("selectFindMatch:completionHandler:")
    private static let revealSelector = NSSelectorFromString("scrollFindMatchToVisible:")
    private static let hideSelector = NSSelectorFromString("_hideFindUI")
    /// `NSTextFinderAsynchronousDocumentFindOptionsCaseInsensitive`, measured: 4 counted both
    /// "Apple" and "apple", every other bit only "Apple".
    private static let caseInsensitiveOption: UInt = 1 << 2

    private typealias Collect = @convention(c) (
        AnyObject, Selector, NSString, AnyObject?, UInt, UInt, @escaping @convention(block) (NSArray, Bool) -> Void
    ) -> Void
    private typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias Select = @convention(c) (AnyObject, Selector, AnyObject, (@convention(block) () -> Void)?) -> Void
    private typealias Reveal = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    /// Whether this WebKit still answers to every call the counted search needs.
    static func canCount(in webView: WKWebView) -> Bool {
        [collectSelector, platformUISelector, selectSelector, revealSelector, hideSelector].allSatisfy(webView.responds(to:))
    }

    /// Every match on the page, in document order across frames, and WebKit's overlay over them.
    ///
    /// Two passes, because WebKit gives either half but not both at once: with its platform find
    /// UI on, each match carries its rectangle and nothing is drawn; with it off, the page dims
    /// around every match and the matches carry no rectangle. The rectangles are what a new
    /// search starts from, so typing never throws the page back to its first match.
    static func matches(of query: String, caseSensitive: Bool, in webView: WKWebView) async -> [Match] {
        let options: UInt = caseSensitive ? 0 : caseInsensitiveOption
        setPlatformUI(true, in: webView)
        let located = await collect(query, options: options, in: webView)
        setPlatformUI(false, in: webView)
        let shown = await collect(query, options: options, in: webView)
        return shown.enumerated().map { index, token in
            let rects = index < located.count ? located[index].value(forKey: "textRects") as? [NSValue] : nil
            return Match(token: token, origin: rects?.first?.rectValue.origin ?? .zero)
        }
    }

    /// Selects the match, scrolls it into view and bounces WebKit's yellow indicator over it.
    static func show(_ match: Match, in webView: WKWebView) {
        unsafeBitCast(webView.method(for: selectSelector), to: Select.self)(webView, selectSelector, match.token, nil)
        unsafeBitCast(webView.method(for: revealSelector), to: Reveal.self)(webView, revealSelector, match.token)
    }

    /// Takes the overlay, the highlights and the indicator off the page.
    static func hide(in webView: WKWebView) {
        guard webView.responds(to: hideSelector) else { return }
        webView.perform(hideSelector)
    }

    /// The public search, for a WebKit without the calls above: it moves to the next match
    /// and says whether there was one.
    static func findNext(_ query: String, caseSensitive: Bool, backwards: Bool, in webView: WKWebView) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = caseSensitive
        configuration.backwards = backwards
        configuration.wraps = true
        return (try? await webView.find(query, configuration: configuration).matchFound) ?? false
    }

    /// The top-left of what is on screen, in the same coordinates as a match's origin.
    static func visibleOrigin(of webView: WKWebView) async -> CGPoint {
        let offsets = try? await webView.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, contentWorld: .defaultClient) as? [Double]
        guard let offsets, offsets.count == 2 else { return .zero }
        return CGPoint(x: offsets[0], y: offsets[1])
    }

    private static func setPlatformUI(_ isOn: Bool, in webView: WKWebView) {
        unsafeBitCast(webView.method(for: platformUISelector), to: SetFlag.self)(webView, platformUISelector, isOn)
    }

    private static func collect(_ query: String, options: UInt, in webView: WKWebView) async -> [NSObject] {
        await withCheckedContinuation { continuation in
            unsafeBitCast(webView.method(for: collectSelector), to: Collect.self)(
                webView, collectSelector, query as NSString, nil, options, UInt(maximumMatches)
            ) { matches, _ in
                continuation.resume(returning: matches.compactMap { $0 as? NSObject })
            }
        }
    }
}
