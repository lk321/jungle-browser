import AppKit
import Combine
import UserNotifications

/// Owns the app-level authorization that lets WebKit present website notifications through
/// macOS Notification Center. Website permissions remain owned by each profile's data store.
@MainActor
final class BrowserNotificationController: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isRequestingAuthorization = false

    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    var isAuthorized: Bool { authorizationStatus == .authorized }
    var canRequestAuthorization: Bool { authorizationStatus == .notDetermined }

    var statusDescription: String {
        switch authorizationStatus {
        case .authorized:
            "Notifications are allowed in macOS."
        case .notDetermined:
            "Allow notifications before a website asks to send them."
        default:
            "Notifications are turned off in macOS."
        }
    }

    func refreshAuthorizationStatus() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await self.notificationCenter.notificationSettings()
            authorizationStatus = settings.authorizationStatus
        }
    }

    func requestAuthorization() {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        Task { [weak self] in
            guard let self else { return }
            _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound])
            let settings = await notificationCenter.notificationSettings()
            authorizationStatus = settings.authorizationStatus
            isRequestingAuthorization = false
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}
