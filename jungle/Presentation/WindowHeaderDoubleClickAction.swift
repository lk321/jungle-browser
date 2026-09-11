import AppKit

/// What a double click on the window header strip does.
///
/// Mirrors the system wide `AppleActionOnDoubleClick` preference instead of hardcoding zoom,
/// so Jungle behaves like every other titlebar on the machine.
enum WindowHeaderDoubleClickAction: Equatable {
    case zoom
    case minimize
    case ignore

    static let preferenceKey: String = "AppleActionOnDoubleClick"

    /// macOS leaves the key unset until the user changes it, and the shipping default is zoom.
    /// An unrecognised value falls back to the same default rather than doing nothing.
    static func resolved(from preference: String?) -> WindowHeaderDoubleClickAction {
        guard let preference else { return .zoom }
        switch preference.lowercased() {
        case "maximize":
            return .zoom
        case "minimize":
            return .minimize
        case "none":
            return .ignore
        default:
            return .zoom
        }
    }

    /// `UserDefaults.standard` searches `NSGlobalDomain`, where this key is written.
    static func systemPreference(in defaults: UserDefaults = .standard) -> WindowHeaderDoubleClickAction {
        resolved(from: defaults.string(forKey: preferenceKey))
    }

    func apply(to window: NSWindow) {
        switch self {
        case .zoom:
            // Already a toggle: it restores the previous frame when the window is zoomed.
            window.zoom(nil)
        case .minimize:
            window.miniaturize(nil)
        case .ignore:
            break
        }
    }
}
