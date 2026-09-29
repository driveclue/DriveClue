import DriveClueCore
import SwiftUI

struct ErrorsView: View {
    var drive: DriveSnapshot

    var body: some View {
        Group {
            if drive.transport == .nvme {
                DiagnosticNotice(title: "Error Log", symbol: "doc.text.magnifyingglass", message: "macOS does not return the NVMe error-log records for this SSD. The error-entry count is available on the dashboard.")
            } else if drive.errors.isEmpty {
                DiagnosticNotice(title: "Error Log", symbol: "checkmark.circle", message: "No errors have been logged for this drive, or this drive does not keep an error log.")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("#").frame(width: 32, alignment: .leading)
                        Text("POWER-ON HOURS").frame(width: 125, alignment: .leading)
                        Text("ERROR").frame(maxWidth: .infinity, alignment: .leading)
                        Text("PRIOR COMMAND").frame(width: 190, alignment: .leading)
                    }
                    .diagnosticTableHeader()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(drive.errors.enumerated()), id: \.element.id) { index, error in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(error.id)").frame(width: 32, alignment: .leading)
                                    Text(error.powerOnHours.map(String.init) ?? "—")
                                        .frame(width: 125, alignment: .leading)
                                    Text(error.summary).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(error.priorCommand).frame(width: 190, alignment: .leading)
                                }
                                .diagnosticTableRow(index: index)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiagnosticTheme.background)
    }
}

struct StatisticsView: View {
    var drive: DriveSnapshot

    var body: some View {
        Group {
            if drive.statistics.isEmpty {
                DiagnosticNotice(title: "Device Statistics", symbol: "tablecells", message: "This drive did not return a statistics log macOS can read.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(drive.statistics) { section in
                            VStack(alignment: .leading, spacing: 9) {
                                SectionHeader(title: section.title, symbol: "tablecells")
                                ForEach(section.entries) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(entry.name)
                                            .foregroundStyle(DiagnosticTheme.muted)
                                            .frame(width: 260, alignment: .leading)
                                        Text(entry.value)
                                            .monospacedDigit()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiagnosticTheme.background)
    }
}

struct SelfTestsView: View {
    @Bindable var model: AppModel
    var drive: DriveSnapshot

    var body: some View {
        VStack(spacing: 0) {
            if drive.supportsSelfTest { controls }
            if drive.selfTests.isEmpty {
                DiagnosticNotice(
                    title: "Self-tests",
                    symbol: "timer",
                    message: drive.selfTestUnavailableReason ?? "No completed self-tests are recorded for this drive."
                )
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("#").frame(width: 32, alignment: .leading)
                        Text("LIFETIME (H)").frame(width: 105, alignment: .leading)
                        Text("TEST TYPE").frame(width: 150, alignment: .leading)
                        Text("PROGRESS").frame(width: 90, alignment: .leading)
                        Text("STATUS").frame(maxWidth: .infinity, alignment: .leading)
                        Text("LBA OF 1ST ERROR").frame(width: 145, alignment: .leading)
                    }
                    .diagnosticTableHeader()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(drive.selfTests.enumerated()), id: \.element.id) { index, test in
                                HStack(spacing: 12) {
                                    Text("\(test.id)").frame(width: 32, alignment: .leading)
                                    Text(test.powerOnHours.map(String.init) ?? "—")
                                        .frame(width: 105, alignment: .leading)
                                    Text(test.testType).frame(width: 150, alignment: .leading)
                                    Text("\(test.progress)%").frame(width: 90, alignment: .leading)
                                    Text(test.status).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(test.failingLBA).frame(width: 145, alignment: .leading)
                                }
                                .diagnosticTableRow(index: index)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiagnosticTheme.background)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Start Short Self-test") { Task { await model.startSelfTest(extended: false) } }
                    .disabled(!drive.supportsSelfTest)
                    .tint(DiagnosticTheme.selection)
                Button("Start Full Self-test") { Task { await model.startSelfTest(extended: true) } }
                    .disabled(!drive.supportsSelfTest)
                    .tint(DiagnosticTheme.green)
                Button("Cancel") { Task { await model.abortSelfTest() } }
                    .disabled(drive.selfTestProgress == nil || drive.transport != .ata)
            }
            .buttonStyle(.borderedProminent)
            if let progress = drive.selfTestProgress {
                ProgressView(value: Double(progress.percent), total: 100) {
                    Text("Self-test in progress… \(progress.percent)%")
                }
                .tint(DiagnosticTheme.green)
                if let minutes = progress.remainingMinutes {
                    Text("About \(minutes) minutes. A full test keeps the Mac awake until it finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let reason = drive.selfTestUnavailableReason {
                Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Short tests usually finish in about \(drive.shortTestMinutes ?? 2) minutes. A full test reads the whole drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.sleepAssertionHeld {
                Text("Sleep is held for this full self-test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(DiagnosticTheme.panel)
    }
}

private extension View {
    func diagnosticTableHeader() -> some View {
        self
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(DiagnosticTheme.muted)
            .padding(.horizontal, 22)
            .frame(height: 27)
            .background(DiagnosticTheme.rowAlternate)
            .overlay(alignment: .bottom) { DiagnosticTheme.line.frame(height: 1) }
    }

    func diagnosticTableRow(index: Int) -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(DiagnosticTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index.isMultiple(of: 2) ? DiagnosticTheme.row : DiagnosticTheme.rowAlternate)
            .textSelection(.enabled)
    }
}

private struct DiagnosticNotice: View {
    var title: String
    var symbol: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: title, symbol: symbol)
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .frame(width: 22)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(DiagnosticTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FreeSpaceSheet: View {
    @Bindable var model: AppModel
    var volume: VolumeInfo
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var percent: Int

    init(model: AppModel, volume: VolumeInfo) {
        self.model = model
        self.volume = volume
        let current = model.settings.freeSpaceThresholds[volume.bsdName]
        _enabled = State(initialValue: current != nil)
        _percent = State(initialValue: current ?? 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Free space on \(volume.name)").font(.title3.weight(.semibold))
            Text("Alerts stay off until you set a limit. DriveClue warns when free space falls below it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Warn when free space is below", isOn: $enabled)
            Stepper(value: $percent, in: 1...50) {
                Text("\(percent)%")
            }
            .disabled(!enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if enabled {
                        model.settings.freeSpaceThresholds[volume.bsdName] = percent
                    } else {
                        model.settings.freeSpaceThresholds.removeValue(forKey: volume.bsdName)
                    }
                    model.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
