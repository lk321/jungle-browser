import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject var settings: BrowserSettings
    @Environment(\.dismiss) private var dismiss

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

            settingsSection("APPEARANCE") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(BrowserAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
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
        }
        .padding(22)
        .frame(width: 430)
        .background(.regularMaterial)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
