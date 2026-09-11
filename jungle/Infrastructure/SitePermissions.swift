import AppKit
import WebKit

/// The answers a site got to the camera, microphone and notification prompts, remembered per
/// origin the way every other browser remembers them. `UserDefaults` holds them: one flat
/// dictionary that has to survive a relaunch and nothing more.
@MainActor
enum SitePermissions {
    enum Kind: String {
        case camera
        case microphone
        case notifications

    }

    /// "use your camera and your microphone", the way a browser words it.
    private static func phrase(for kinds: [Kind]) -> String {
        let devices = kinds.compactMap { kind -> String? in
            switch kind {
            case .camera: "your camera"
            case .microphone: "your microphone"
            case .notifications: nil
            }
        }
        return devices.isEmpty ? "send you notifications" : "use \(devices.joined(separator: " and "))"
    }

    private static let defaultsKey = "jungle.site-permissions"

    /// A capture request covers one device or both, and a stored pair answers the combined
    /// request without asking twice.
    static func decision(for origin: String, kinds: [Kind]) -> Bool? {
        let stored = stored()
        let answers = kinds.map { stored[key(origin, $0)] }
        if answers.contains(false) { return false }
        return answers.allSatisfy { $0 == true } ? true : nil
    }

    static func remember(_ allowed: Bool, for origin: String, kinds: [Kind]) {
        var stored = stored()
        kinds.forEach { stored[key(origin, $0)] = allowed }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    static func forget(_ origin: String) {
        var stored = stored()
        stored.keys.filter { $0.hasPrefix("\(origin)|") }.forEach { stored.removeValue(forKey: $0) }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    /// Asks once per origin and device, then reuses the answer.
    ///
    /// A page that asks the same thing twice before the user has answered waits on the prompt
    /// already on screen, instead of stacking a second one behind it.
    static func request(_ kinds: [Kind], origin: String, in window: NSWindow?) async -> Bool {
        if let decision = decision(for: origin, kinds: kinds) { return decision }
        let key = "\(origin)|\(kinds.map(\.rawValue).sorted().joined(separator: "+"))"
        if inFlight[key] != nil {
            return await withCheckedContinuation { inFlight[key]?.append($0) }
        }
        inFlight[key] = []
        let choice = await ask(
            "“\(origin)” wants to \(phrase(for: kinds)).",
            information: "You can change this later by asking the site again.",
            buttons: ["Allow", "Don't Allow"],
            in: window
        )
        let allowed = choice == 0
        remember(allowed, for: origin, kinds: kinds)
        inFlight.removeValue(forKey: key)?.forEach { $0.resume(returning: allowed) }
        return allowed
    }

    /// Callers waiting on a prompt that is already on screen, keyed by origin and what it asks.
    private static var inFlight: [String: [CheckedContinuation<Bool, Never>]] = [:]

    /// Runs the alert as a sheet on the browser window, or standalone if the web view is not
    /// in a window yet. Always answers exactly once: a dropped answer leaves the page waiting
    /// on `getUserMedia` forever, which looks exactly like a denied permission.
    static func ask(_ message: String, information: String, buttons: [String], in window: NSWindow?) async -> Int {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = information
            buttons.forEach { alert.addButton(withTitle: $0) }
            guard let window, window.isVisible else {
                continuation.resume(returning: alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
                return
            }
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            }
        }
    }

    /// `https://meet.google.com`, the same shape every browser puts in its permission prompt.
    static func describe(_ origin: WKSecurityOrigin) -> String {
        let port = origin.port == 0 || origin.port == 80 || origin.port == 443 ? "" : ":\(origin.port)"
        return "\(origin.protocol)://\(origin.host)\(port)"
    }

    static func describe(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func key(_ origin: String, _ kind: Kind) -> String { "\(origin)|\(kind.rawValue)" }

    private static func stored() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
    }
}
