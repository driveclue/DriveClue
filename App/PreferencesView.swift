import DriveClueCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var model: AppModel
    @State private var password = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            advanced.tabItem { Label("Advanced", systemImage: "envelope") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            updates.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .padding(16)
        .onAppear { password = Keychain.load(account: model.settings.smtpUsername) ?? "" }
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

    private var advanced: some View {
        Form {
            Toggle("Send email reports", isOn: $model.settings.emailEnabled)
            Picker("Send", selection: $model.settings.emailTrigger) {
                ForEach(EmailReportTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("When health is below", isOn: $model.settings.emailHealthEnabled)
            Stepper("\(model.settings.emailHealthBelow)%", value: $model.settings.emailHealthBelow, in: 1...90)
            Toggle("When performance is below", isOn: $model.settings.emailPerformanceEnabled)
            Stepper("\(model.settings.emailPerformanceBelow)%", value: $model.settings.emailPerformanceBelow, in: 1...90)
            Toggle("When SSD life is below", isOn: $model.settings.emailSSDLifeEnabled)
            Stepper("\(model.settings.emailSSDLifeBelow)%", value: $model.settings.emailSSDLifeBelow, in: 1...90)
            Toggle("When a self-test finishes", isOn: $model.settings.emailOnSelfTestComplete)
            Toggle("Also send a daily report", isOn: $model.settings.dailyReportEnabled)
            Stepper("At hour \(model.settings.dailyReportHour)", value: $model.settings.dailyReportHour, in: 0...23)
            TextField("Send to", text: $model.settings.emailTo)
            TextField("Send from", text: $model.settings.emailFrom)
            Picker("Delivery", selection: $model.settings.emailUseAppleMail) {
                Text("Apple Mail").tag(true)
                Text("SMTP").tag(false)
            }
            .pickerStyle(.radioGroup)
            if !model.settings.emailUseAppleMail {
                TextField("Server", text: $model.settings.smtpHost)
                TextField("Port", value: $model.settings.smtpPort, format: .number)
                Toggle("Use TLS (connect securely, typically port 465)", isOn: $model.settings.smtpUseTLS)
                Toggle("Authenticate", isOn: $model.settings.smtpUseAuth)
                TextField("Username", text: $model.settings.smtpUsername)
                SecureField("Password", text: $password)
                    .onChange(of: password) { _, newValue in
                        Keychain.save(account: model.settings.smtpUsername, password: newValue)
                    }
            }
            Button("Send Test Email") { Task { await model.sendTestEmail() } }
                .disabled(model.settings.emailTo.isEmpty)
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
