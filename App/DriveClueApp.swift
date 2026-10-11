import AppKit
import DriveClueCore
import SwiftUI

@main
struct DriveClueApp: App {
    @NSApplicationDelegateAdaptor(DriveClueAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DriveClue", id: "main") {
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
            CommandMenu("Navigate") {
                Button("Next Drive") { model.selectAdjacentDrive(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Drive") { model.selectAdjacentDrive(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Divider()
                Button("Dashboard") { model.selectPage(.dashboard) }.keyboardShortcut("1", modifiers: .command)
                Button("Storage Analyzer") { model.selectPage(.usage) }.keyboardShortcut("2", modifiers: .command)
                Button("Indicators") { model.selectPage(.indicators) }.keyboardShortcut("3", modifiers: .command)
                Button("Statistics") { model.selectPage(.statistics) }.keyboardShortcut("4", modifiers: .command)
                Button("Errors") { model.selectPage(.errors) }.keyboardShortcut("5", modifiers: .command)
                Button("Self-tests and Benchmark") { model.selectPage(.selfTests) }.keyboardShortcut("6", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateController.checkNow() }
                    .keyboardShortcut("u", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Check Drives Now") { Task { await model.refreshWithIOErrors() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            let attention = model.drives.contains { $0.hasHealthReading && $0.smartStatus != .ok }
            let unavailable = model.drives.contains { !$0.hasHealthReading }
            Image(systemName: attention ? "exclamationmark.triangle.fill" : (unavailable ? "internaldrive.fill.badge.questionmark" : "internaldrive"))
                .symbolRenderingMode(.multicolor)
        }
        .menuBarExtraStyle(.window)
    }
}

private final class DriveClueAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // First touch starts Sparkle, putting background update checks on schedule.
        _ = UpdateController.shared
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow.canBecomeMain,
              !NSApp.windows.contains(where: { $0 !== closedWindow && $0.isVisible && $0.canBecomeMain }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The dropdown panel shown from the status item. A window-style MenuBarExtra
/// gives room for per-drive stat cards that a plain NSMenu cannot render.
struct MenuBarMenu: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    private var worst: IndicatorStatus? {
        model.drives.filter(\.hasHealthReading).map(\.smartStatus).max()
    }

    private var healthSummary: String {
        guard !model.drives.isEmpty else { return "No drives detected" }
        let unavailable = model.drives.filter { !$0.hasHealthReading }.count
        if let worst, worst != .ok {
            return unavailable > 0 ? "\(worst.title) · \(unavailable) unavailable" : "Worst: \(worst.title)"
        }
        if unavailable > 0 { return "\(unavailable) health reading\(unavailable == 1 ? "" : "s") unavailable" }
        return "All drives OK"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.drives.isEmpty {
                emptyState
            } else {
                ForEach(model.drives) { drive in
                    MenuBarDriveCard(drive: drive) {
                        dismiss()
                        open(driveID: drive.id)
                    }
                }
            }
            Rectangle().fill(DiagnosticTheme.line).frame(height: 1)
            footer
        }
        .padding(12)
        .frame(width: 352)
        .background(DiagnosticTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiagnosticTheme.cyan)
                Text("DriveClue")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DiagnosticTheme.text)
                Spacer()
                Text(healthSummary)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(worst == nil || model.drives.contains(where: { !$0.hasHealthReading }) ? DiagnosticTheme.amber : IndicatorStyle.color(worst ?? .ok))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(DiagnosticTheme.muted.opacity(0.18), in: Capsule())
            }
            HStack(spacing: 6) {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking…")
                        .font(.system(size: 10))
                        .foregroundStyle(DiagnosticTheme.muted)
                }
                Spacer()
                if let checked = model.drives.map(\.checkedAt).max() {
                    Text("Last check \(checked.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(DiagnosticTheme.muted)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No drives detected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DiagnosticTheme.text)
            Text("Click Check Now below to rescan.")
                .font(.system(size: 10))
                .foregroundStyle(DiagnosticTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            MenuPanelButton(symbol: "arrow.clockwise", title: model.isRefreshing ? "Checking…" : "Check Now") {
                dismiss()
                Task { await model.refreshWithIOErrors() }
            }
            .disabled(model.isRefreshing)
            MenuPanelButton(symbol: "macwindow", title: "Open DriveClue") {
                dismiss()
                open(driveID: nil)
            }
            .keyboardShortcut("o")
            MenuPanelButton(symbol: "arrow.down.circle", title: "Check for Updates…") {
                dismiss()
                UpdateController.checkNow()
            }
            MenuPanelButton(symbol: "power", title: "Quit DriveClue") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func open(driveID: String?) {
        if let driveID {
            model.selection = SidebarSelection(driveID: driveID, page: .dashboard)
        }
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One tappable card per drive: health and usage meters plus a grid of the
/// stats people check most often (temperature, uptime, lifetime writes).
private struct MenuBarDriveCard: View {
    let drive: DriveSnapshot
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            content
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(drive.displayName), status \(drive.hasHealthReading ? drive.statusLine : "health unavailable")\(drive.presentableHealth.map { ", health \(Int($0)) percent" } ?? "")")
        .accessibilityHint("Opens this drive in the main window")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DiagnosticTheme.text)
                        .lineLimit(1)
                    Text("\(drive.model) · \(drive.devicePath)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DiagnosticTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(drive.hasHealthReading ? drive.statusLine.uppercased() : "UNAVAILABLE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(drive.hasHealthReading ? IndicatorStyle.color(drive.smartStatus) : DiagnosticTheme.muted, in: RoundedRectangle(cornerRadius: 4))
            }
            if let health = drive.presentableHealth, let band = drive.presentableHealthBand {
                meter(label: "Health", value: health, color: IndicatorStyle.color(band))
            } else {
                Label("Health reading unavailable", systemImage: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(DiagnosticTheme.amber)
            }
            if let usage = usageSummary {
                meter(label: "Used", value: usage.usedPercent, color: usageColor(freePercent: usage.freePercent))
                Text("\(ByteFormat.bytes(usage.availableBytes)) free of \(ByteFormat.bytes(usage.totalBytes))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                if let temp = drive.temperatureCelsius {
                    statChip(icon: "thermometer.medium", value: "\(temp) °C", label: "Temperature", tint: temperatureColor)
                }
                if let hours = drive.powerOnHours {
                    statChip(icon: "clock.arrow.circlepath", value: Self.compactUptime(hours), label: "Power on", tint: DiagnosticTheme.text)
                }
                if let written = drive.bytesWritten, written > 0 {
                    statChip(icon: "arrow.down.circle", value: ByteFormat.bytes(written), label: "Lifetime written", tint: DiagnosticTheme.text)
                }
                if drive.hasHealthReading, let life = drive.ssdLife {
                    statChip(
                        icon: "gauge.with.dots.needle.67percent",
                        value: "\(Int(life.rounded()))%",
                        label: "SSD life left",
                        tint: IndicatorStyle.color(drive.ssdLifeBand ?? drive.healthBand)
                    )
                }
                if drive.capacityBytes > 0 {
                    statChip(icon: "internaldrive", value: ByteFormat.bytes(drive.capacityBytes), label: "Capacity", tint: DiagnosticTheme.text)
                }
            }
        }
        .padding(10)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(hovering ? DiagnosticTheme.line : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func meter(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(DiagnosticTheme.muted)
                .frame(width: 38, alignment: .leading)
            DiagnosticBar(value: value, color: color)
            Text(String(format: "%.0f%%", value))
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(DiagnosticTheme.text)
                .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(value)) percent")
    }

    private func statChip(icon: String, value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(DiagnosticTheme.muted)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.row, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Aggregates the user-facing volumes the way the dashboard treats them:
    /// a System volume sharing space with its Data volume is not counted twice.
    private var usageSummary: (usedPercent: Double, freePercent: Double, availableBytes: UInt64, totalBytes: UInt64)? {
        let usable = drive.volumes.filter { $0.isUserFacing && $0.totalBytes > 0 && !($0.role == "System" && $0.availableBytes == 0) }
        guard !usable.isEmpty else { return nil }
        let total = usable.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let available = usable.reduce(UInt64(0)) { $0 + min($1.availableBytes, $1.totalBytes) }
        guard total > 0 else { return nil }
        let freePercent = Double(available) / Double(total) * 100
        return (100 - freePercent, freePercent, available, total)
    }

    private func usageColor(freePercent: Double) -> Color {
        if freePercent < 10 { return DiagnosticTheme.red }
        if freePercent < 20 { return DiagnosticTheme.deepOrange }
        if freePercent < 30 { return DiagnosticTheme.amber }
        return DiagnosticTheme.green
    }

    private var temperatureColor: Color {
        guard let temp = drive.temperatureCelsius else { return DiagnosticTheme.text }
        let limit = (drive.recommendedTempMax ?? 0) > 0 ? drive.recommendedTempMax! : 60
        if temp >= limit { return DiagnosticTheme.red }
        if temp >= limit - 10 { return DiagnosticTheme.amber }
        return DiagnosticTheme.green
    }

    /// Power-on hours in the shortest unit that stays readable at chip size.
    static func compactUptime(_ hours: Int) -> String {
        if hours < 48 { return "\(hours) h" }
        let days = Double(hours) / 24
        if days < 45 { return days < 10 ? String(format: "%.1f d", days) : String(format: "%.0f d", days) }
        let months = days / 30.44
        if months < 18 { return String(format: "%.1f mo", months) }
        return String(format: "%.1f yr", days / 365.25)
    }
}

/// A full-width action row that reads like a menu item inside the panel.
private struct MenuPanelButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.cyan)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(DiagnosticTheme.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
