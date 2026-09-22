import AppKit
import WebKit

/// The last responder in the window's chain, where a key nobody wanted ends up. A key the
/// page reads without `preventDefault` — a slide deck's arrow keys, a game's letters — comes
/// back from WebKit as unhandled and climbs the chain to its end, and AppKit's answer there
/// is the "can't do that" beep on every press. Measured: an arrow, a space and a letter on a
/// page that listens for them all reached the end of the chain.
///
/// Only keys typed into a page stop here. The page already had them, and a web browser does not
/// beep at typing. A ⌘ shortcut nothing answered still beeps, as does a key in a native field:
/// those are the actions that cannot be done. Sitting last, it never takes a key from anything
/// that handles it — SwiftUI's key handlers and the window run first.
final class WebKeyPressSink: NSResponder {
    /// Stateless, and AppKit does not retain a next responder.
    static let shared = WebKeyPressSink()

    static func install(in window: NSWindow) {
        var last: NSResponder = window
        while let next = last.nextResponder {
            if next === shared { return }
            last = next
        }
        last.nextResponder = shared
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || !Self.isInWebPage(event.window?.firstResponder) else { return }
        super.keyDown(with: event)
    }

    private static func isInWebPage(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}
