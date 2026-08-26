import AppKit

@MainActor
enum ApplicationIconController {
    static func update(for appearance: BrowserAppearance) {
        NSApplication.shared.appearance = applicationAppearance(for: appearance)
        NSApplication.shared.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private static func applicationAppearance(for appearance: BrowserAppearance) -> NSAppearance? {
        switch appearance {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}
