import AppKit

@MainActor
enum ApplicationIconController {
    static func update(for appearance: BrowserAppearance) {
        NSApplication.shared.appearance = applicationAppearance(for: appearance)
        // A custom applicationIconImage freezes the Dock tile into a flat bitmap; nil lets macOS
        // render AppIcon.icon itself (sharp at every size, follows Clear/Tinted).
        NSApplication.shared.applicationIconImage = nil
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
