import DriveClueCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL

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
                        pageRow(drive, page: .usage, count: nil)
                        pageRow(drive, page: .indicators, count: drive.indicators.count)
                        pageRow(drive, page: .statistics, count: drive.statistics.reduce(0) { $0 + $1.entries.count })
                        pageRow(drive, page: .errors, count: drive.errors.count)
                        pageRow(drive, page: .selfTests, count: nil)
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
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 29, height: 29)
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
                    Text(AppInfo.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DiagnosticTheme.sidebarText)
                    Text(AppInfo.versionLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DiagnosticTheme.sidebarMuted)
                    Text(AppInfo.gitHubDisplay)
                        .font(.system(size: 10))
                        .foregroundStyle(DiagnosticTheme.sidebarMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            sidebarLinkButton(
                "View on GitHub",
                systemImage: "chevron.left.forwardslash.chevron.right",
                url: AppInfo.gitHubURL,
                help: "Open DriveClue on GitHub"
            )
            sidebarLinkButton(
                "Buy me a coffee",
                systemImage: "cup.and.saucer.fill",
                url: AppInfo.buyMeACoffeeURL,
                help: "Support DriveClue with a donation",
                tint: Color(red: 1.0, green: 0.867, blue: 0.0)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 12)
    }

    /// A full-width link button for the sidebar footer. Pass `tint` for a filled
    /// brand-colored button; otherwise it uses the neutral sidebar style.
    private func sidebarLinkButton(
        _ title: String,
        systemImage: String,
        url: URL,
        help: String,
        tint: Color? = nil
    ) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint == nil ? DiagnosticTheme.sidebarText : Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint ?? Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(DiagnosticTheme.sidebarMuted.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help(help)
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
                Image(systemName: !drive.hasHealthReading ? "questionmark.circle.fill" : (drive.smartStatus == .ok ? "checkmark" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(!drive.hasHealthReading ? DiagnosticTheme.sidebarMuted : (drive.smartStatus == .ok ? DiagnosticTheme.green : DiagnosticTheme.amber))
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .foregroundStyle(selected ? .white : DiagnosticTheme.sidebarText)
            .background(selected ? DiagnosticTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(drive.displayName), health \(drive.hasHealthReading ? drive.statusLine : "unavailable")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pageRow(_ drive: DriveSnapshot, page: DrivePage, count: Int?) -> some View {
        let selected = model.selection == SidebarSelection(driveID: drive.id, page: page)
        let symbol: String = switch page {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .usage: "chart.pie.fill"
        case .indicators: "chart.bar.fill"
        case .errors: "text.badge.xmark"
        case .statistics: "tablecells.fill"
        case .selfTests: "speedometer"
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
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? DiagnosticTheme.selection : DiagnosticTheme.sidebarMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(selected ? Color.white : Color.white.opacity(0.8), in: Capsule())
                }
            }
            .padding(.leading, 40)
            .padding(.trailing, 10)
            .frame(height: 29)
            .foregroundStyle(selected ? .white : DiagnosticTheme.sidebarText)
            .background(selected ? DiagnosticTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(drive.displayName), \(page.title)\(count.map { ", \($0) items" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            case .usage: UsageView(model: model, drive: drive)
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
        .background(DiagnosticTheme.footer)
        .overlay(alignment: .top) { Color.black.opacity(0.25).frame(height: 1) }
    }
}
