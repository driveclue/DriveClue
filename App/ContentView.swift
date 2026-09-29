import DriveClueCore
import SwiftUI

enum DiagnosticTheme {
    static let sidebar = Color(red: 0.89, green: 0.92, blue: 0.95)
    static let sidebarText = Color(red: 0.15, green: 0.20, blue: 0.25)
    static let sidebarMuted = Color(red: 0.42, green: 0.49, blue: 0.55)
    static let selection = Color(red: 0.22, green: 0.51, blue: 0.76)
    static let background = Color(red: 0.29, green: 0.33, blue: 0.36)
    static let panel = Color(red: 0.38, green: 0.42, blue: 0.45)
    static let row = Color(red: 0.36, green: 0.40, blue: 0.43)
    static let rowAlternate = Color(red: 0.33, green: 0.37, blue: 0.40)
    static let text = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let muted = Color(red: 0.76, green: 0.80, blue: 0.83)
    static let line = Color.white.opacity(0.13)
    static let green = Color(red: 0.43, green: 0.83, blue: 0.20)
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.20)
    static let red = Color(red: 0.97, green: 0.36, blue: 0.34)
}

struct DiagnosticBar: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("\(Int(value)) percent")
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) · Build \(build)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 244)
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                VStack(spacing: 0) {
                    header
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(DiagnosticTheme.background)
                .foregroundStyle(DiagnosticTheme.text)
                .environment(\.colorScheme, .dark)
            }
            footer
        }
        .background(DiagnosticTheme.background)
        .ignoresSafeArea(.container, edges: .top)
        .alert("DriveClue", isPresented: alertShown) {
            Button("OK", role: .cancel) { model.alertText = nil }
        } message: {
            Text(model.alertText ?? "")
        }
        .sheet(item: $model.freeSpaceTarget) { volume in
            FreeSpaceSheet(model: model, volume: volume)
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alertText != nil }, set: { if !$0 { model.alertText = nil } })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarBrand
            Rectangle()
                .fill(DiagnosticTheme.sidebarMuted.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 15)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("DIAGNOSTICS")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(DiagnosticTheme.sidebarMuted)
                        .padding(.horizontal, 15)
                        .padding(.top, 15)
                        .padding(.bottom, 8)
                    ForEach(model.drives) { drive in
                        driveRow(drive)
                        pageRow(drive, page: .indicators, count: drive.indicators.count)
                        pageRow(drive, page: .statistics, count: drive.statistics.reduce(0) { $0 + $1.entries.count })
                        pageRow(drive, page: .errors, count: drive.errors.count)
                        pageRow(drive, page: .selfTests, count: drive.selfTests.count)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            sidebarInfo
        }
        .background(DiagnosticTheme.sidebar)
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DiagnosticTheme.selection)
                .frame(width: 29, height: 29)
                .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("DriveClue")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DiagnosticTheme.sidebarText)
                Text("Know what your drive is telling you.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DiagnosticTheme.sidebarMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.top, 42)
        .padding(.bottom, 9)
    }

    private var sidebarInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(DiagnosticTheme.sidebarMuted.opacity(0.22))
                .frame(height: 1)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DiagnosticTheme.sidebarMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DriveClue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DiagnosticTheme.sidebarText)
                    Text(versionLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DiagnosticTheme.sidebarMuted)
                    Text("Made by Tran Tuan")
                        .font(.system(size: 10))
                        .foregroundStyle(DiagnosticTheme.sidebarMuted)
                }
                Spacer(minLength: 0)
            }
            Button {
                // Destination will be added when the support link is ready.
            } label: {
                Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.91, green: 0.45, blue: 0.16), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Support link coming soon")
            Button {
                if let url = URL(string: "https://github.com/driveclue/DriveClue") {
                    openURL(url)
                }
            } label: {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiagnosticTheme.sidebarText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(DiagnosticTheme.sidebarMuted.opacity(0.18), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Open DriveClue on GitHub")
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 12)
    }

    private func driveRow(_ drive: DriveSnapshot) -> some View {
        let selected = model.selection == SidebarSelection(driveID: drive.id, page: .dashboard)
        return Button {
            model.selection = SidebarSelection(driveID: drive.id, page: .dashboard)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: drive.isSSD ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? .white : DiagnosticTheme.sidebarMuted)
                    .frame(width: 23)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(drive.model)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .opacity(0.8)
                }
                Spacer(minLength: 2)
                Image(systemName: drive.smartStatus == .ok ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(drive.smartStatus == .ok ? DiagnosticTheme.green : DiagnosticTheme.amber)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .foregroundStyle(selected ? .white : DiagnosticTheme.sidebarText)
            .background(selected ? DiagnosticTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let volume = drive.volumes.first(where: { $0.isUserFacing && $0.role != "System" && $0.mountPath != nil }) {
                Button("Free Space Monitoring…") { model.freeSpaceTarget = volume }
            }
        }
    }

    private func pageRow(_ drive: DriveSnapshot, page: DrivePage, count: Int) -> some View {
        let selected = model.selection == SidebarSelection(driveID: drive.id, page: page)
        let symbol: String = switch page {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .indicators: "chart.bar.fill"
        case .errors: "text.badge.xmark"
        case .statistics: "tablecells.fill"
        case .selfTests: "timer"
        }
        return Button {
            model.selection = SidebarSelection(driveID: drive.id, page: page)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? .white : DiagnosticTheme.selection)
                    .frame(width: 17)
                Text(page.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? DiagnosticTheme.selection : DiagnosticTheme.sidebarMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selected ? Color.white : Color.white.opacity(0.8), in: Capsule())
            }
            .padding(.leading, 40)
            .padding(.trailing, 10)
            .frame(height: 29)
            .foregroundStyle(selected ? .white : DiagnosticTheme.sidebarText)
            .background(selected ? DiagnosticTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let drive = model.selectedDrive {
                Text(drive.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("/") .foregroundStyle(DiagnosticTheme.muted)
                Text(model.selection?.page.title ?? "Dashboard")
                    .font(.system(size: 13))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .lineLimit(1)
            } else {
                Text("DriveClue").font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            Button {
                Task { await model.refreshWithIOErrors() }
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            Button("Save Report…") { model.export(format: .text) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(DiagnosticTheme.background)
        .overlay(alignment: .bottom) { DiagnosticTheme.line.frame(height: 1) }
    }

    @ViewBuilder
    private var detail: some View {
        if let drive = model.selectedDrive {
            switch model.selection?.page ?? .dashboard {
            case .dashboard: DashboardView(model: model, drive: drive)
            case .indicators: IndicatorsView(model: model, drive: drive)
            case .errors: ErrorsView(drive: drive)
            case .statistics: StatisticsView(drive: drive)
            case .selfTests: SelfTestsView(model: model, drive: drive)
            }
        } else {
            ContentUnavailableView("No drives", systemImage: "internaldrive", description: Text("DriveClue lists internal and Thunderbolt disks macOS exposes."))
        }
    }

    private var footer: some View {
        HStack {
            if let checked = model.drives.map(\.checkedAt).max() {
                Text("Last checked: \(checked.formatted(date: .abbreviated, time: .standard))")
            } else {
                Text("Waiting for the first drive check")
            }
            Spacer()
            Text(model.isRefreshing ? "Checking drives…" : "\(model.drives.count) drive\(model.drives.count == 1 ? "" : "s")")
        }
        .font(.system(size: 11))
        .foregroundStyle(DiagnosticTheme.sidebarText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(red: 0.76, green: 0.79, blue: 0.81))
        .overlay(alignment: .top) { Color.black.opacity(0.25).frame(height: 1) }
    }
}

struct RatingCard: View {
    var title: String
    var value: Double
    var band: HealthBand

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 206, alignment: .leading)
            Text(band.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 20)
                .background(IndicatorStyle.color(band), in: RoundedRectangle(cornerRadius: 4))
            DiagnosticBar(value: value, color: IndicatorStyle.color(band))
                .frame(maxWidth: 250)
            Text(String(format: "%.1f%%", value))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(band.title) \(Int(value)) percent")
    }
}

struct SectionHeader: View {
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiagnosticTheme.muted)
                .frame(width: 17)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(DiagnosticTheme.text)
        .padding(.vertical, 3)
    }
}
