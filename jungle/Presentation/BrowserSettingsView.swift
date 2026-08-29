import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject var settings: BrowserSettings
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var defaultBrowserController = DefaultBrowserController()
    @StateObject private var notificationController = BrowserNotificationController()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Browser settings", systemImage: "gearshape.fill")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }

            settingsSection("SEARCH") {
                Picker("Default search engine", selection: $settings.searchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.menu)
            }

            settingsSection("NEW TABS") {
                Picker("Open new tabs with", selection: $settings.newTabDestination) {
                    ForEach(BrowserNewTabDestination.allCases) { destination in
                        Label(destination.title, systemImage: destination.symbol).tag(destination)
                    }
                }
                .pickerStyle(.menu)

                if settings.newTabDestination == .native {
                    Text("⌘T opens Jungle's native search page. Enter a full URL to open it directly, or search with your selected engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.newTabDestination == .custom {
                    TextField("https://www.example.com", text: $settings.customNewTabAddress)
                        .textFieldStyle(.roundedBorder)
                    Text("Use an address such as youtube.com or https://www.example.com. Jungle falls back to your search engine while it is incomplete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.newTabDestination == .youtube {
                    Text("⌘T opens YouTube directly. Your selected search engine still handles searches from the address bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("⌘T opens the home page of your selected search engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection("APPEARANCE") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(BrowserAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsSection("DEFAULT BROWSER") {
                HStack(spacing: 10) {
                    Image(systemName: defaultBrowserController.isDefaultBrowser ? "checkmark.circle.fill" : "safari")
                        .foregroundStyle(defaultBrowserController.isDefaultBrowser ? Color.green : Color.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(defaultBrowserController.isDefaultBrowser ? "Jungle is your default browser" : "Use Jungle as your default browser")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Text("Opens web links from other apps in Jungle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(defaultBrowserController.isDefaultBrowser ? "Default" : "Make default") {
                        defaultBrowserController.makeDefaultBrowser()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(defaultBrowserController.isDefaultBrowser ? .gray : .green)
                    .disabled(defaultBrowserController.isDefaultBrowser || defaultBrowserController.isUpdating)
                }
                if defaultBrowserController.isUpdating {
                    ProgressView("Updating default browser…")
                        .controlSize(.small)
                }
                if let failureDescription = defaultBrowserController.failureDescription {
                    Text(failureDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsSection("MEMORY") {
                Picker("Suspend inactive tabs after", selection: $settings.tabSleepInterval) {
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                }
                .pickerStyle(.menu)
                Text("Suspended tabs release their WebKit view and reload their last address when opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("NOTIFICATIONS") {
                HStack(spacing: 10) {
                    Image(systemName: notificationController.isAuthorized ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(notificationController.isAuthorized ? Color.green : Color.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notificationController.isAuthorized ? "Mac notifications are enabled" : "Enable website notifications")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Text(notificationController.statusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if notificationController.isAuthorized {
                        Button("System Settings", action: notificationController.openSystemSettings)
                            .buttonStyle(.bordered)
                    } else if notificationController.canRequestAuthorization {
                        Button("Allow", action: notificationController.requestAuthorization)
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(notificationController.isRequestingAuthorization)
                    } else {
                        Button("System Settings", action: notificationController.openSystemSettings)
                            .buttonStyle(.bordered)
                    }
                }
                Text("Each website still asks for permission separately. Permissions are kept with its profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("PROFILES") {
                ForEach(store.profiles) { profile in
                    ProfileSettingsRow(profile: profile, store: store, canDelete: store.profiles.count > 1)
                }
                Button(action: store.createProfile) {
                    Label("Add profile", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .pointerCursor()
            }
        }
        .frame(width: 386, alignment: .leading)
        .padding(22)
        .background(.regularMaterial)
        .onAppear {
            defaultBrowserController.refresh()
            notificationController.refreshAuthorizationStatus()
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProfileSettingsRow: View {
    let profile: BrowserProfile
    @ObservedObject var store: BrowserStore
    let canDelete: Bool
    @State private var name: String
    @State private var symbol: String
    @State private var tint: ProfileTint
    @State private var isEditing = false
    @State private var isHovering = false

    private let symbols = ["person.crop.circle", "briefcase", "book.closed", "paintpalette", "star", "gamecontroller"]

    init(profile: BrowserProfile, store: BrowserStore, canDelete: Bool) {
        self.profile = profile
        self.store = store
        self.canDelete = canDelete
        _name = State(initialValue: profile.name)
        _symbol = State(initialValue: profile.symbol)
        _tint = State(initialValue: profile.tint)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isEditing ? symbol : profile.symbol)
                .foregroundStyle(Color(nsColor: (isEditing ? tint : profile.tint).color))
                .frame(width: 25, height: 25)
                .background(Color(nsColor: (isEditing ? tint : profile.tint).color).opacity(0.14), in: Circle())
            if isEditing {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(symbols, id: \.self) { option in
                        Button { symbol = option } label: { Label(option, systemImage: option) }
                    }
                } label: {
                    Image(systemName: "face.smiling")
                }
                .menuStyle(.borderlessButton)
                .help("Change icon")
                Menu {
                    ForEach(ProfileTint.allCases, id: \.self) { option in
                        Button { tint = option } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(nsColor: option.color))
                                    .frame(width: 12, height: 12)
                                Text(option.rawValue.capitalized)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: tint.color))
                }
                .menuStyle(.borderlessButton)
                .help("Change color")
                Button { save() } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                    .help("Save profile")
                Button { cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                    .help("Cancel")
                if canDelete {
                    Button(role: .destructive) { store.deleteProfile(profile.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                    .help("Delete profile")
                }
            } else {
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                Spacer()
                Button { isEditing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                    .help("Edit profile")
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
        }
        .onHover { isHovering = $0 }
    }

    private func save() {
        store.updateProfile(profile.id, name: name, symbol: symbol, tint: tint)
        isEditing = false
    }

    private func cancel() {
        name = profile.name
        symbol = profile.symbol
        tint = profile.tint
        isEditing = false
    }
}
