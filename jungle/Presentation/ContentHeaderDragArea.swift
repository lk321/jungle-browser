import AppKit
import SwiftUI
import WebKit

/// A titlebar-tall strip across the top of the page that drags the window, and gives every
/// click back to the page underneath it.
///
/// The window has no titlebar of its own, so without this the only way to move it is the
/// sidebar header, which disappears with the sidebar. The strip covers page content, so it
/// stops the one press that could become a window drag and lets everything else through:
/// a press that never moves is replayed on the web view as the click it was.
struct ContentHeaderDragArea: NSViewRepresentable {
    /// The height of a standard titlebar, measured without a window so the strip lines up
    /// with the traffic lights beside it instead of guessing at a constant.
    static let height: CGFloat = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height

    func makeNSView(context: Context) -> NSView {
        ContentHeaderDragView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
    }
}

private final class ContentHeaderDragView: NSView {
    /// How far the pointer travels before a press reads as a window drag instead of a click.
    private let dragThreshold: CGFloat = 3
    /// Set only while this view looks for what sits under it, so its own hit test steps aside.
    private var isTransparentToHitTesting = false

    /// Dragging an inactive window should not cost the user a throwaway activation click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Scrolling, hovering, cursor changes, context menus and any drag that started below the
    /// strip keep reaching the page: only the left press that could become a window drag is
    /// claimed here, and an unknown event always falls through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isTransparentToHitTesting else { return nil }
        guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = event.locationInWindow
        var startsWindowDrag = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard next.type != .leftMouseUp else {
                forwardClick(from: event, to: next)
                return
            }
            let location = next.locationInWindow
            guard hypot(location.x - origin.x, location.y - origin.y) > dragThreshold else { continue }
            startsWindowDrag = true
            break
        }

        // Runs its own tracking loop until mouse up, and picks the window up where it is.
        guard startsWindowDrag else { return }
        window.performDrag(with: event)
    }

    /// A press that never became a drag belongs to the page, so it is replayed on the web view
    /// under the strip with its own click count intact. Nothing else that can appear there has
    /// a control in its top strip, so anything but a web view is left alone.
    private func forwardClick(from down: NSEvent, to up: NSEvent) {
        guard let webView = webViewUnderStrip(at: down.locationInWindow) else { return }
        webView.mouseDown(with: down)
        webView.mouseUp(with: up)
    }

    private func webViewUnderStrip(at locationInWindow: NSPoint) -> WKWebView? {
        guard let contentView = window?.contentView else { return nil }
        isTransparentToHitTesting = true
        defer { isTransparentToHitTesting = false }
        // WebKit hands back one of its own internal views, so the web view is found by walking up.
        var candidate: NSView? = contentView.hitTest(locationInWindow)
        while let view = candidate {
            if let webView = view as? WKWebView { return webView }
            candidate = view.superview
        }
        return nil
    }
}
