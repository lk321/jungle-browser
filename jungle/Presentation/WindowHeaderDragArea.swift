import AppKit
import SwiftUI

/// A bounded strip of the sidebar header that drags the window the way a titlebar does.
///
/// The window deliberately keeps `isMovableByWindowBackground` off so SwiftUI's sidebar drag
/// and drop owns every other pointer drag. Only this view starts a window drag, and it is laid
/// out to occupy the empty space beside the profile menu so it never covers a control.
struct WindowHeaderDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowHeaderDragView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
    }
}

private final class WindowHeaderDragView: NSView {
    /// Dragging an inactive window should not cost the user a throwaway activation click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hit testing arrives in the superview's coordinate space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard !coversVisibleWindowButton(at: convert(point, from: superview)) else { return nil }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount < 2 else {
            WindowHeaderDoubleClickAction.systemPreference().apply(to: window)
            return
        }
        // Runs its own tracking loop until mouse up, and is a no-op when the pointer never moves.
        window.performDrag(with: event)
    }

    /// The traffic lights live in the titlebar container, which AppKit orders above the content
    /// view, so they already win hit testing. Excluding their frames makes that an invariant of
    /// this view instead of an assumption about AppKit's view ordering.
    private func coversVisibleWindowButton(at point: NSPoint) -> Bool {
        guard let window else { return false }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttonTypes {
            guard let button = window.standardWindowButton(buttonType), !button.isHidden else { continue }
            let frame: NSRect = convert(button.bounds, from: button).insetBy(dx: -4, dy: -4)
            guard frame.contains(point) else { continue }
            return true
        }
        return false
    }
}
