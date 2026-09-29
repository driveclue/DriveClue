import DriveClueCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            updates.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .padding(16)
    }

    private var general: some View {
        Form {
            Stepper(value: $model.settings.checkIntervalMinutes, in: 5...720, step: 5) {
                Text("Check every \(model.settings.checkIntervalMinutes) minutes")
            }
            Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
            Toggle("Show the menu bar icon", isOn: $model.settings.showMenuBarIcon)
            Toggle("Menu bar only, hide the window at launch", isOn: $model.settings.menuBarOnly)
            Toggle("Weekly note when every drive is still OK", isOn: $model.settings.weeklyAllClear)
            Text("Free-space alerts are off until you set one from a volume on the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }

    private var appearance: some View {
        Form {
            Toggle("Monochrome menu bar icon", isOn: $model.settings.monochromeMenuBarIcon)
            Text("Health colors stay on the ratings and status text. The window follows the system appearance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }

    private var updates: some View {
        Form {
            TextField("Appcast URL", text: $model.settings.updateFeedURL)
            Button("Check for Updates") { Task { await model.checkForUpdates() } }
            Text("Leave the URL empty until you host a Sparkle appcast. DriveClue stays free either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}
