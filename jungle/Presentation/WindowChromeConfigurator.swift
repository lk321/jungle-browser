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
    private var trafficLightsVisible = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Self.configure(window, trafficLightsVisible: trafficLightsVisible)
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
    }

    static func configure(_ window: NSWindow, trafficLightsVisible: Bool) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = !trafficLightsVisible
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !trafficLightsVisible
        window.standardWindowButton(.zoomButton)?.isHidden = !trafficLightsVisible
    }
}
