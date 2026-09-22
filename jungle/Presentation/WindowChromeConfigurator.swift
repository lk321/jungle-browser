import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
    }
}

private final class WindowChromeView: NSView {
    private var visibilityObserver: NSObjectProtocol?
    private var keyboardMonitor: Any?
    private var isCyclingTabs = false
    private var trafficLightsVisible = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Self.configure(window, trafficLightsVisible: trafficLightsVisible)
        installKeyboardMonitor(for: window)
        WebKeyPressSink.install(in: window)
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: .jungleTrafficLightsVisibility,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let isVisible = notification.userInfo?["isVisible"] as? Bool, let window = self.window else { return }
            self.trafficLightsVisible = isVisible
            Self.configure(window, trafficLightsVisible: isVisible)
        }
    }

    deinit {
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
        }
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }

    static func configure(_ window: NSWindow, trafficLightsVisible: Bool) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Interactive sidebar content owns pointer drags. Letting AppKit treat the entire
        // transparent surface as a window drag region races SwiftUI's drop gestures.
        window.isMovableByWindowBackground = false
        // The sidebar's material blends with what is behind the window, which an opaque
        // window never lets through: without these two the glass renders as flat gray.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.closeButton)?.isHidden = !trafficLightsVisible
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !trafficLightsVisible
        window.standardWindowButton(.zoomButton)?.isHidden = !trafficLightsVisible
    }

    private func installKeyboardMonitor(for window: NSWindow) {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self, weak window] event in
            guard let self, let window, NSApp.keyWindow === window else { return event }

            if event.type == .flagsChanged, !event.modifierFlags.contains(.control), self.isCyclingTabs {
                self.isCyclingTabs = false
                NotificationCenter.default.post(name: .jungleDismissTabCycle, object: nil)
                return event
            }

            if event.type == .keyDown,
               self.isCyclingTabs,
               let offset = Self.tabCycleOffset(for: event.keyCode) {
                NotificationCenter.default.post(
                    name: .jungleMoveTabWhileCycling,
                    object: nil,
                    userInfo: ["offset": offset]
                )
                return nil
            }

            guard event.type == .keyDown, event.modifierFlags.contains(.control) else { return event }
            switch event.keyCode {
            case 48:
                if self.isCyclingTabs {
                    NotificationCenter.default.post(name: .jungleAdvanceTabCycle, object: nil)
                } else {
                    self.isCyclingTabs = true
                    NotificationCenter.default.post(name: .jungleBeginTabCycle, object: nil)
                }
            default:
                return event
            }
            return nil
        }
    }

    private static func tabCycleOffset(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 43, 123:
            -1
        case 47, 124:
            1
        default:
            nil
        }
    }
}
