import Charts
import DriveClueCore
import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel
    var drive: DriveSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                identity
                problems
                important
                temperature
                volumes
                charts
                capabilities
                diagnosis
                events
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DiagnosticTheme.background)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Advanced S.M.A.R.T. Status")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 206, alignment: .leading)
                Text(drive.hasHealthReading ? drive.statusLine.uppercased() : "UNAVAILABLE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 64, minHeight: 20)
                    .padding(.horizontal, drive.hasHealthReading ? 0 : 6)
                    .background(drive.hasHealthReading ? IndicatorStyle.color(drive.smartStatus) : DiagnosticTheme.muted, in: RoundedRectangle(cornerRadius: 4))
                if drive.hasHealthReading {
                    Text(drive.issueCount == 0 ? "No issues found" : drive.verdict)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(drive.issueCount == 0 ? DiagnosticTheme.muted : DiagnosticTheme.amber)
                } else {
                    Text("Health reading unavailable")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DiagnosticTheme.amber)
                }
            }
            if let health = drive.presentableHealth, let band = drive.presentableHealthBand {
                RatingCard(title: "Overall Health", value: health, band: band)
            } else {
                Label("Overall Health unavailable — no reliable health reading", systemImage: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DiagnosticTheme.amber)
                    .accessibilityLabel("Overall Health unavailable. No reliable health reading.")
            }
            if drive.hasHealthReading, let performance = drive.performance, let band = drive.performanceBand {
                RatingCard(title: "Overall Performance", value: performance, band: band)
            }
            if drive.hasHealthReading, let life = drive.ssdLife, let band = drive.ssdLifeBand {
                RatingCard(title: "SSD Lifetime Left", value: life, band: band)
            }
            if let error = drive.readError {
                Text(error).font(.system(size: 12)).foregroundStyle(DiagnosticTheme.amber)
            }
        }
        .panel(padding: 16)
    }

    @ViewBuilder
    private var charts: some View {
        let samples = model.histories[drive.id] ?? []
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "History", symbol: "chart.xyaxis.line", tint: DiagnosticTheme.purple)
                if samples.count < 3, let sample = samples.last {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(DiagnosticTheme.muted)
                        Text("\(samples.count) check\(samples.count == 1 ? "" : "s") saved · Latest \(sample.takenAt.formatted(date: .abbreviated, time: .shortened))")
                        Spacer()
                        Text("Trends after three checks")
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                    .font(.system(size: 12))
                } else {
                    Chart(samples) { sample in
                        LineMark(x: .value("Time", sample.takenAt), y: .value("Health", sample.health))
                            .foregroundStyle(by: .value("Series", "Health"))
                        if let life = sample.ssdLife {
                            LineMark(x: .value("Time", sample.takenAt), y: .value("Life", life))
                                .foregroundStyle(by: .value("Series", "SSD life"))
                        }
                    }
                    .frame(height: 130)
                    .chartYScale(domain: 0...100)
                    if samples.contains(where: { $0.temperature != nil }) {
                        Chart(samples) { sample in
                            if let temp = sample.temperature {
                                LineMark(x: .value("Time", sample.takenAt), y: .value("Temperature", temp))
                                    .foregroundStyle(DiagnosticTheme.amber)
                            }
                        }
                        .frame(height: 80)
                        .chartYAxisLabel("Temperature °C")
                    }
                    if samples.contains(where: { $0.bytesWritten != nil }) {
                        Chart(samples) { sample in
                            if let bytes = sample.bytesWritten {
                                LineMark(x: .value("Time", sample.takenAt), y: .value("Terabytes written", bytes / 1_000_000_000_000))
                                    .foregroundStyle(DiagnosticTheme.green)
                            }
                        }
                        .frame(height: 70)
                    }
                    Text("Health and SSD life are percentages. Temperature and total writes use separate scales.")
                        .font(.caption).foregroundStyle(DiagnosticTheme.muted)
                }
                if drive.isSSD, let note = model.history.writeRateDescription(driveID: drive.id, latestBytes: drive.bytesWritten) {
                    Text(note).font(.caption).foregroundStyle(DiagnosticTheme.muted)
                }
                if drive.isSSD, let projection = model.history.lifeProjectionDescription(driveID: drive.id, latestLife: drive.ssdLife) {
                    Text(projection).font(.caption).foregroundStyle(DiagnosticTheme.muted)
                }
            }
            .panel()
        }
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Volumes", symbol: "externaldrive.fill", tint: DiagnosticTheme.teal)
            ForEach(drive.volumes.filter(\.isUserFacing)) { volume in
                VStack(alignment: .leading, spacing: 8) {
                    let freePercent = volumeFreePercent(volume)
                    HStack {
                        Text(volume.name).font(.subheadline.weight(.semibold))
                        Text(volume.role).font(.caption).foregroundStyle(DiagnosticTheme.muted)
                        Spacer()
                        Text(volume.role == "System" && volume.availableBytes == 0
                             ? (drive.volumes.contains(where: { $0.role == "Data" }) ? "Space shared with Data" : "Free space unavailable")
                             : "\(ByteFormat.bytes(volume.availableBytes)) free of \(ByteFormat.bytes(volume.totalBytes)) · \(String(format: "%.1f", freePercent))% free")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                    if volume.totalBytes > 0 && !(volume.role == "System" && volume.availableBytes == 0) {
                        DiagnosticBar(
                            value: 100 - freePercent,
                            color: volumeUsageColor(freePercent: freePercent)
                        )
                        .accessibilityLabel(String(format: "%.1f%% used, %.1f%% free", 100 - freePercent, freePercent))
                    }
                    if volume.purgeableBytes > 0 {
                        Text("Purgeable \(ByteFormat.bytes(volume.purgeableBytes))")
                            .font(.caption2)
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .panel()
    }

    private func volumeFreePercent(_ volume: VolumeInfo) -> Double {
        guard volume.totalBytes > 0 else { return 0 }
        return Double(min(volume.availableBytes, volume.totalBytes)) / Double(volume.totalBytes) * 100
    }

    private func volumeUsageColor(freePercent: Double) -> Color {
        if freePercent < 10 { return DiagnosticTheme.red }
        if freePercent < 20 { return DiagnosticTheme.deepOrange }
        if freePercent < 30 { return DiagnosticTheme.amber }
        return DiagnosticTheme.green
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Problems Summary", symbol: "checkmark.shield.fill", tint: DiagnosticTheme.amber)
            if drive.hasHealthReading {
                problemRow("Failed indicators", life: drive.lifeFailed, preFail: drive.preFailFailed)
                problemRow("Failing indicators", life: drive.lifeFailing, preFail: drive.preFailFailing)
                problemRow("Warnings", life: drive.lifeWarnings, preFail: drive.preFailWarnings)
                grid("Failed self-tests", "\(drive.failedSelfTests)")
            } else {
                Text("Health indicators and self-test status unavailable for this check.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiagnosticTheme.amber)
            }
            if model.ioErrorUnavailableDrives.contains(drive.id) {
                grid("I/O errors in system log (recent)", "Unavailable — macOS did not allow this log check")
            } else if let reading = model.ioErrorReadings[drive.id] {
                grid("I/O errors in system log (recent)", "\(reading.count) · checked \(reading.checkedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                grid("I/O errors in system log (recent)", "Not checked — use Check now to scan the system log")
            }
            if let over = drive.overTemperatureMinutes { grid("Time over temperature", "\(over) minutes") }
            if let under = drive.underTemperatureMinutes { grid("Time under temperature", "\(under) minutes") }
        }
        .panel()
    }

    private func problemRow(_ title: String, life: Int, preFail: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(DiagnosticTheme.muted)
                .frame(width: 220, alignment: .leading)
            Text("\(life + preFail)  (life-span \(life) / pre-fail \(preFail))")
                .foregroundStyle(life + preFail > 0 ? DiagnosticTheme.amber : DiagnosticTheme.text)
            if life + preFail > 0 {
                Button {
                    model.selection = SidebarSelection(driveID: drive.id, page: .indicators)
                    model.statusFilter = title.hasPrefix("Failed") ? .failed : (title.hasPrefix("Failing") ? .failing : .warning)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help("Show these indicators")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    private var important: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Important Indicators", symbol: "heart.text.square.fill", tint: DiagnosticTheme.rose)
            ForEach(Array(drive.indicators.filter(\.isImportant).enumerated()), id: \.element.id) { index, indicator in
                HStack(spacing: 10) {
                    Text(String(format: "%03d", indicator.id))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DiagnosticTheme.muted)
                        .frame(width: 32, alignment: .leading)
                    Text(indicator.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(indicator.rawDisplay)
                        .monospacedDigit()
                        .frame(width: 112, alignment: .trailing)
                    if let rating = indicator.rating {
                        DiagnosticBar(value: rating, color: IndicatorStyle.color(indicator.status))
                            .frame(width: 92)
                        Text("\(Int(rating))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                    Text(indicator.status.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IndicatorStyle.color(indicator.status))
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(index.isMultiple(of: 2) ? DiagnosticTheme.row : DiagnosticTheme.rowAlternate)
            }
        }
        .panel()
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "General Information", symbol: "info.circle.fill", tint: DiagnosticTheme.selection)
            grid("Volumes", drive.volumes.filter(\.isUserFacing).map(\.name).joined(separator: ", "))
            grid("Device", drive.devicePath)
            grid("Serial", drive.serial.isEmpty ? "—" : drive.serial)
            if let wwn = drive.wwn { grid("WWN", wwn) }
            grid("Capacity", "\(ByteFormat.bytes(drive.capacityBytes)) (\(ByteFormat.decimal(drive.capacityBytes)) bytes)")
            grid("Sector size", "\(drive.sectorSize) bytes")
            grid("Family", drive.modelFamily)
            grid("Model", drive.model)
            grid("Firmware", drive.firmware.isEmpty ? "—" : drive.firmware)
            if let hours = drive.powerOnHours { grid("Power on", ByteFormat.durationHours(hours)) }
            if let cycles = drive.powerCycleCount { grid("Power cycles", "\(cycles)") }
        }
        .panel()
    }

    private var temperature: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Temperature", symbol: "thermometer.medium", tint: DiagnosticTheme.orange)
            if let current = drive.temperatureCelsius {
                grid("Current", "\(current) °C")
                if let change = temperatureChange {
                    grid("Change since last check", String(format: "%+.1f °C", change))
                }
                // NVMe drives carry no lifetime extremes in the health log, so the
                // recorded values come from DriveClue's own saved checks.
                let recorded = drive.transport == .nvme
                if let min = drive.temperatureMin { grid(recorded ? "Recorded minimum" : "Lifetime minimum", "\(min) °C") }
                if let max = drive.temperatureMax { grid(recorded ? "Recorded maximum" : "Lifetime maximum", "\(max) °C") }
                if let low = drive.recommendedTempMin, let high = drive.recommendedTempMax {
                    grid("Typical range", "\(low)–\(high) °C")
                }
                if let low = drive.temperatureLimitMin, let high = drive.temperatureLimitMax {
                    grid("Operating limits", "\(low)–\(high) °C")
                }
            } else {
                Text("This drive did not report a temperature.").foregroundStyle(DiagnosticTheme.muted)
            }
        }
        .panel()
    }

    private var temperatureChange: Double? {
        let temps = (model.histories[drive.id] ?? []).compactMap(\.temperature)
        guard temps.count >= 2, let last = temps.last, let previous = temps.dropLast().last else { return nil }
        return last - previous
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Device Capabilities", symbol: "checkmark.seal.fill", tint: DiagnosticTheme.green)
            ForEach(drive.capabilities) { item in
                grid(item.name, item.value)
            }
        }
        .panel()
    }

    @ViewBuilder
    private var diagnosis: some View {
        let lines = Diagnosis.lines(for: drive)
        if !lines.isEmpty && drive.smartStatus != .ok {
            SectionHeader(title: "Diagnosis", symbol: "stethoscope", tint: DiagnosticTheme.red)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.callout)
            }
        }
    }

    @ViewBuilder
    private var events: some View {
        let rows = model.events[drive.id] ?? []
        if !rows.isEmpty {
            SectionHeader(title: "Events", symbol: "clock.fill", tint: DiagnosticTheme.indigo)
            ForEach(rows) { event in
                HStack {
                    Text(event.takenAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(event.message).font(.callout)
                }
            }
        }
    }

    private func grid(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(DiagnosticTheme.muted)
                .frame(width: 220, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}
