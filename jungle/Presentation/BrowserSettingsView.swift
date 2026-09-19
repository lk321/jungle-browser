import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject var settings: BrowserSettings
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var defaultBrowserController = DefaultBrowserController()
    @StateObject private var notificationController = BrowserNotificationController()
    @State private var selectedCategory: SettingsCategory = .general
    @ObservedObject private var contentBlocking = ContentBlocking.shared
    @State private var isCheckingForListUpdates = false
    /// Every site that has answered the notification prompt, with its answer.
    @State private var notificationSites: [String: Bool] = [:]

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Label(selectedCategory.title, systemImage: selectedCategory.symbol)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
                .padding(.horizontal, 24)
                .frame(height: 64)

                Divider()

                ScrollView {
                    settingsContent
                        .padding(24)
                }
            }
        }
        .frame(width: 720, height: 540)
        .background(.regularMaterial)
        .onAppear {
            defaultBrowserController.refresh()
            notificationController.refreshAuthorizationStatus()
            notificationSites = SitePermissions.decisions(for: .notifications)
        }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("JUNGLE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            ForEach(SettingsCategory.allCases) { category in
                Button { selectedCategory = category } label: {
                    Label(category.title, systemImage: category.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedCategory == category ? Color.primary : Color.secondary)
                .background(selectedCategory == category ? Color.green.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            Text("Preferences")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 20)
        .frame(width: 176, alignment: .leading)
    }

    @ViewBuilder
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selectedCategory.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch selectedCategory {
            case .general:
                generalSettings
            case .adBlocking:
                adBlockingSettings
            case .workspace:
                workspaceSettings
            case .system:
                systemSettings
            case .extensions:
                extensionSettings
            case .profiles:
                profileSettings
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generalSettings: some View {
        Group {
            settingsSection("Search") {
                Picker("Default search engine", selection: $settings.searchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.menu)
            }

            settingsSection("New tabs") {
                Picker("Open new tabs with", selection: $settings.newTabDestination) {
                    ForEach(BrowserNewTabDestination.allCases) { destination in
                        Label(destination.title, systemImage: destination.symbol).tag(destination)
                    }
                }
                .pickerStyle(.menu)
                newTabDescription
            }

            settingsSection("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(BrowserAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    @ViewBuilder
    private var newTabDescription: some View {
        if settings.newTabDestination == .native {
            caption("⌘T opens Jungle's native search page. Enter a full URL to open it directly, or search with your selected engine.")
        } else if settings.newTabDestination == .custom {
            TextField("https://www.example.com", text: $settings.customNewTabAddress)
                .textFieldStyle(.roundedBorder)
            caption("Use an address such as youtube.com or https://www.example.com. Jungle falls back to your search engine while it is incomplete.")
        } else if settings.newTabDestination == .youtube {
            caption("⌘T opens YouTube directly. Your selected search engine still handles searches from the address bar.")
        } else {
            caption("⌘T opens the home page of your selected search engine.")
        }
    }

    private var adBlockingSettings: some View {
        Group {
            settingsSection("Protection") {
                adBlockingToggle(
                    "Block ads and trackers",
                    caption: "Ad and tracker requests never leave your Mac. Turning this off stops the filter lists entirely.",
                    isOn: $settings.adBlocking.blocksAdsAndTrackers
                )
                Divider()
                adBlockingToggle(
                    "Hide the space a blocked ad leaves",
                    caption: "Closes the empty frame around a blocked ad. This is the part most likely to take a piece of a page with it, so turn it off first if a site looks wrong.",
                    isOn: $settings.adBlocking.hidesBlockedAdSpace
                )
                .disabled(!settings.adBlocking.blocksAdsAndTrackers)
                Divider()
                adBlockingToggle(
                    "Block pop-ups from embedded players",
                    caption: "A video player inside a page asks for a window on its own behalf, never yours. Pop-ups the page itself opens, such as a sign-in window, still work.",
                    isOn: $settings.adBlocking.blocksEmbeddedPlayerPopups
                )
                Divider()
                adBlockingToggle(
                    "Get past \"disable your ad blocker\" walls",
                    caption: "Answers the detectors these pages use and takes down the notice they put over the page. Applies to a tab the next time it loads.",
                    isOn: $settings.adBlocking.bypassesAdblockWalls
                )
                Divider()
                adBlockingToggle(
                    "Skip ads inside YouTube videos",
                    caption: "YouTube serves its video ads from the same address as the video, so no filter list can reach them.",
                    isOn: $settings.adBlocking.skipsYouTubeAds
                )
            }

            settingsSection("Filter lists") {
                HStack(spacing: 10) {
                    Image(systemName: settings.adBlocking.blocksAdsAndTrackers ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(settings.adBlocking.blocksAdsAndTrackers ? Color.green : Color.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listStatusTitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        caption(listStatusDetail)
                    }
                    Spacer(minLength: 0)
                    Button(isCheckingForListUpdates ? "Checking…" : "Check now") {
                        isCheckingForListUpdates = true
                        Task {
                            await ContentBlocking.shared.refreshNow()
                            isCheckingForListUpdates = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingForListUpdates || contentBlocking.isRefreshing)
                }
                caption("EasyList and EasyPrivacy are rebuilt several times a day. Jungle checks every six hours and on launch, asking the server whether anything changed — an unchanged list costs one small request and no recompiling.")
            }
        }
    }

    private var listStatusTitle: String {
        guard settings.adBlocking.blocksAdsAndTrackers else { return "Blocking is off" }
        return contentBlocking.activeRuleListCount == 0 ? "Preparing filter lists…" : "Filter lists are active"
    }

    private var listStatusDetail: String {
        guard let lastRefresh = contentBlocking.lastRefresh else {
            return "EasyList and EasyPrivacy · not downloaded yet"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "EasyList and EasyPrivacy · updated \(formatter.localizedString(for: lastRefresh, relativeTo: .now))"
    }

    private func adBlockingToggle(_ title: String, caption text: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                caption(text)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var workspaceSettings: some View {
        settingsSection("Memory") {
            Picker("Suspend inactive tabs after", selection: $settings.tabSleepInterval) {
                Text("30 seconds").tag(TimeInterval(30))
                Text("1 minute").tag(TimeInterval(60))
                Text("5 minutes").tag(TimeInterval(300))
                Text("15 minutes").tag(TimeInterval(900))
            }
            .pickerStyle(.menu)
            caption("Suspended tabs release their WebKit view and reload their last address when opened. When macOS runs low on memory, background tabs sleep sooner. Pinned and Quick Access tabs stay awake, and sleep only when memory is critical.")
        }
    }

    private var systemSettings: some View {
        Group {
            settingsSection("Default browser") {
                HStack(spacing: 10) {
                    Image(systemName: defaultBrowserController.isDefaultBrowser ? "checkmark.circle.fill" : "safari")
                        .foregroundStyle(defaultBrowserController.isDefaultBrowser ? Color.green : Color.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(defaultBrowserController.isDefaultBrowser ? "Jungle is your default browser" : "Use Jungle as your default browser")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        caption("Opens web links from other apps in Jungle.")
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

            settingsSection("Notifications") {
                HStack(spacing: 10) {
                    Image(systemName: notificationController.isAuthorized ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(notificationController.isAuthorized ? Color.green : Color.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notificationController.isAuthorized ? "Mac notifications are enabled" : "Enable website notifications")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        caption(notificationController.statusDescription)
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
                caption("Each website still asks for permission separately. Permissions are kept with its profile.")
            }

            settingsSection("Website notifications") {
                if notificationSites.isEmpty {
                    caption("No website has asked to send notifications yet.")
                }
                ForEach(notificationSites.keys.sorted(), id: \.self) { origin in
                    HStack(spacing: 10) {
                        Text(origin)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Toggle(
                            "Allow notifications from \(origin)",
                            isOn: Binding(
                                get: { notificationSites[origin] == true },
                                set: { setNotificationPermission($0, for: origin) }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        Button {
                            setNotificationPermission(nil, for: origin)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove, so the site asks again")
                        .accessibilityLabel("Remove \(origin)")
                    }
                }
                caption("A site allowed to notify keeps its tab awake so it can post. Turn it off to let the tab sleep and free its memory; remove it to have the site ask again.")
            }
        }
    }

    /// `nil` forgets the answer, so the site asks again next time.
    private func setNotificationPermission(_ allowed: Bool?, for origin: String) {
        if let allowed {
            SitePermissions.remember(allowed, for: origin, kinds: [.notifications])
        } else {
            SitePermissions.forget([.notifications], for: origin)
        }
        // Answers are baked into every tab's script; open pages pick the change up on their next load.
        WebViewPool.shared.reinstallUserScripts()
        notificationSites = SitePermissions.decisions(for: .notifications)
    }

    private var extensionSettings: some View {
        Group {
            settingsSection("Low-resource compatibility") {
                Text("WebKit cannot run Chrome extensions, their scripts, popups, or service workers. Jungle imports only static Manifest V3 declarative block rules and compiles them into WebKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(action: store.importChromeExtension) {
                    Label("Import extension folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(store.isExtensionImporting)

                if store.isExtensionImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Compiling rules…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.extensionImportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.extensions.isEmpty {
                ContentUnavailableView(
                    "No extensions installed",
                    systemImage: "puzzlepiece",
                    description: Text("Import an unpacked Chrome Manifest V3 folder with declarative network rules."))
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                ForEach(store.extensions) { browserExtension in
                    extensionRow(browserExtension)
                }
            }
        }
    }

    private func extensionRow(_ browserExtension: BrowserExtension) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.green)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(browserExtension.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                caption("v\(browserExtension.version) · \(browserExtension.ruleCount) WebKit rules")
                if browserExtension.unsupportedRuleCount > 0 {
                    Text("\(browserExtension.unsupportedRuleCount) Chrome-only rules were skipped")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                "Enable \(browserExtension.name)",
                isOn: Binding(
                    get: { browserExtension.isEnabled },
                    set: { store.setExtensionEnabled($0, for: browserExtension.id) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            Button(role: .destructive) { store.removeExtension(browserExtension.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove extension")
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var profileSettings: some View {
        settingsSection("Profiles") {
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

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case adBlocking
    case workspace
    case system
    case extensions
    case profiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .adBlocking: "Ad blocking"
        case .workspace: "Workspace"
        case .system: "System"
        case .extensions: "Extensions"
        case .profiles: "Profiles"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .adBlocking: "shield.lefthalf.filled"
        case .workspace: "rectangle.3.group"
        case .system: "macbook"
        case .extensions: "puzzlepiece.extension"
        case .profiles: "person.2"
        }
    }

    var description: String {
        switch self {
        case .general: "Search, new tabs, and appearance."
        case .adBlocking: "What Jungle blocks, and the lists it blocks from."
        case .workspace: "Keep inactive tabs from using memory."
        case .system: "Mac integration and website notifications."
        case .extensions: "Manage compatible declarative WebKit rules."
        case .profiles: "Separate workspaces, data, and bookmarks."
        }
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
