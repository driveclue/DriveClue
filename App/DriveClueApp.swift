import AppKit
import DriveClueCore
import SwiftUI

@main
struct DriveClueApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 620)
                .task { await model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save Report…") { model.export(format: .text) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Export CSV…") { model.export(format: .csv) }
                Button("Export JSON…") { model.export(format: .json) }
            }
            CommandGroup(after: .toolbar) {
                Button("Check Drives Now") { Task { await model.refreshWithIOErrors() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $model.settings.showMenuBarIcon) {
            MenuBarMenu(model: model)
        } label: {
            let attention = model.drives.contains { $0.smartStatus != .ok }
            Image(systemName: attention && !model.settings.monochromeMenuBarIcon ? "internaldrive.fill" : "internaldrive")
                .symbolRenderingMode(model.settings.monochromeMenuBarIcon ? .monochrome : .multicolor)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView(model: model)
                .frame(width: 560, height: 460)
        }
    }
}

struct MenuBarMenu: View {
    @Bindable var model: AppModel
    private var worst: IndicatorStatus {
        model.drives.map(\.smartStatus).max() ?? .ok
    }

    var body: some View {
        Text(model.drives.isEmpty ? "No drives yet" : "Worst status: \(worst.title)")
        if let checked = model.drives.map(\.checkedAt).max() {
            Text("Last check \(checked.formatted(date: .omitted, time: .standard))")
        }
        Divider()
        ForEach(model.drives) { drive in
            Button("\(drive.displayName) — \(drive.statusLine)") {
                model.selection = SidebarSelection(driveID: drive.id, page: .dashboard)
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
        }
        Divider()
        Button("Check Now") { Task { await model.refresh() } }
        Button("Open DriveClue") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        .keyboardShortcut("o")
        SettingsLink()
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
