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
                Text(drive.statusLine.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 20)
                    .background(IndicatorStyle.color(drive.smartStatus), in: RoundedRectangle(cornerRadius: 4))
                Text(drive.issueCount == 0 ? "No issues found" : drive.verdict)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(drive.issueCount == 0 ? DiagnosticTheme.muted : DiagnosticTheme.amber)
            }
            RatingCard(title: "Overall Health", value: drive.overallHealth, band: drive.healthBand)
            if let performance = drive.performance, let band = drive.performanceBand {
                RatingCard(title: "Overall Performance", value: performance, band: band)
            }
            if let life = drive.ssdLife, let band = drive.ssdLifeBand {
                RatingCard(title: "SSD Lifetime Left", value: life, band: band)
            }
            if let error = drive.readError {
                Text(error).font(.system(size: 12)).foregroundStyle(DiagnosticTheme.amber)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var charts: some View {
        let samples = model.histories[drive.id] ?? []
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "History", symbol: "chart.xyaxis.line")
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
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Volumes", symbol: "square.stack.3d.up")
            ForEach(drive.volumes.filter(\.isUserFacing)) { volume in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(volume.name).font(.subheadline.weight(.semibold))
                        Text(volume.role).font(.caption).foregroundStyle(DiagnosticTheme.muted)
                        Spacer()
                        Text(volume.role == "System" && volume.availableBytes == 0
                             ? (drive.volumes.contains(where: { $0.role == "Data" }) ? "Space shared with Data" : "Free space unavailable")
                             : "\(ByteFormat.bytes(volume.availableBytes)) free of \(ByteFormat.bytes(volume.totalBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                    if volume.totalBytes > 0 && !(volume.role == "System" && volume.availableBytes == 0) {
                        DiagnosticBar(
                            value: Double(volume.totalBytes - min(volume.availableBytes, volume.totalBytes)) / Double(volume.totalBytes) * 100,
                            color: volume.availableBytes < volume.totalBytes / 10 ? DiagnosticTheme.amber : DiagnosticTheme.green
                        )
                    }
                    if volume.purgeableBytes > 0 {
                        Text("Purgeable \(ByteFormat.bytes(volume.purgeableBytes))")
                            .font(.caption2)
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    if volume.role != "System" { model.freeSpaceTarget = volume }
                }
                .help(volume.role == "System" ? "System and Data share the same APFS space" : "Set a free-space alert for this volume")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Problems Summary", symbol: "checkmark.shield")
            problemRow("Failed indicators", life: drive.lifeFailed, preFail: drive.preFailFailed)
            problemRow("Failing indicators", life: drive.lifeFailing, preFail: drive.preFailFailing)
            problemRow("Warnings", life: drive.lifeWarnings, preFail: drive.preFailWarnings)
            grid("Failed self-tests", "\(drive.failedSelfTests)")
            grid("I/O errors in system log", "\(drive.ioErrorCount)")
            if let over = drive.overTemperatureMinutes { grid("Time over temperature", "\(over) minutes") }
            if let under = drive.underTemperatureMinutes { grid("Time under temperature", "\(under) minutes") }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
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
            SectionHeader(title: "Important Indicators", symbol: "heart.text.square")
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "General Information", symbol: "info.circle")
            grid("Volumes", drive.volumes.filter(\.isUserFacing).map(\.name).joined(separator: ", "))
            grid("Device", drive.devicePath)
            grid("Serial", drive.serial.isEmpty ? "—" : drive.serial)
            if let wwn = drive.wwn { grid("WWN", wwn) }
            grid("Capacity", ByteFormat.bytes(drive.capacityBytes))
            grid("Sector size", "\(drive.sectorSize) bytes")
            grid("Family", drive.modelFamily)
            grid("Model", drive.model)
            grid("Firmware", drive.firmware.isEmpty ? "—" : drive.firmware)
            if let hours = drive.powerOnHours { grid("Power on", ByteFormat.durationHours(hours)) }
            if let cycles = drive.powerCycleCount { grid("Power cycles", "\(cycles)") }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private var temperature: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Temperature", symbol: "thermometer.medium")
            if let current = drive.temperatureCelsius {
                grid("Current", "\(current) °C")
                if let min = drive.temperatureMin { grid("Lifetime minimum", "\(min) °C") }
                if let max = drive.temperatureMax { grid("Lifetime maximum", "\(max) °C") }
                if let low = drive.recommendedTempMin, let high = drive.recommendedTempMax {
                    grid("Typical range", "\(low)–\(high) °C")
                }
            } else {
                Text("This drive did not report a temperature.").foregroundStyle(DiagnosticTheme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Device Capabilities", symbol: "checkmark.seal")
            ForEach(drive.capabilities) { item in
                grid(item.name, item.value)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var diagnosis: some View {
        let lines = Diagnosis.lines(for: drive)
        if !lines.isEmpty && drive.smartStatus != .ok {
            SectionHeader(title: "Diagnosis", symbol: "stethoscope")
            ForEach(lines, id: \.self) { line in
                Text(line).font(.callout)
            }
        }
    }

    @ViewBuilder
    private var events: some View {
        let rows = model.events[drive.id] ?? []
        if !rows.isEmpty {
            SectionHeader(title: "Events", symbol: "clock")
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

struct IndicatorsView: View {
    @Bindable var model: AppModel
    var drive: DriveSnapshot

    private var rows: [HealthIndicator] {
        drive.indicators.filter { indicator in
            switch model.typeFilter {
            case .any: break
            case .preFail: if indicator.kind != .preFail { return false }
            case .lifeSpan: if indicator.kind != .lifeSpan { return false }
            }
            switch model.statusFilter {
            case .any: break
            case .ok: if indicator.status != .ok { return false }
            case .warning: if indicator.status != .warning { return false }
            case .failing: if indicator.status != .failing { return false }
            case .failed: if indicator.status != .failed { return false }
            }
            let query = model.indicatorQuery.trimmingCharacters(in: .whitespaces)
            if query.isEmpty { return true }
            if query.hasPrefix("#"), Int(query.dropFirst()) == indicator.id { return true }
            return indicator.name.localizedCaseInsensitiveContains(query) || "\(indicator.id)".contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            columnHeader
            if rows.isEmpty {
                ContentUnavailableView("No matching indicators", systemImage: "line.3.horizontal.decrease.circle", description: Text("Change a filter or search term to see indicators."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, indicator in
                            indicatorRow(indicator, index: index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
            if let indicator = rows.first(where: { $0.id == model.selectedIndicatorID }) {
                inspector(indicator)
            }
        }
        .background(DiagnosticTheme.background)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Type", selection: $model.typeFilter) {
                ForEach(TypeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            Picker("Status", selection: $model.statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            Spacer(minLength: 4)
            TextField("Search indicators or #id", text: $model.indicatorQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background(DiagnosticTheme.panel)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("ID").frame(width: 27, alignment: .leading)
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("RAW VALUE").frame(width: 102, alignment: .leading)
            Text("VALUE").frame(width: 112, alignment: .leading)
            Text("STATUS").frame(width: 158, alignment: .leading)
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.5)
        .foregroundStyle(DiagnosticTheme.muted)
        .padding(.horizontal, 22)
        .frame(height: 27)
        .background(DiagnosticTheme.rowAlternate)
        .overlay(alignment: .bottom) { DiagnosticTheme.line.frame(height: 1) }
    }

    private func indicatorRow(_ indicator: HealthIndicator, index: Int) -> some View {
        let selected = model.selectedIndicatorID == indicator.id
        return Button {
            model.selectedIndicatorID = indicator.id
        } label: {
            HStack(spacing: 8) {
                Text("\(indicator.id)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 27, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(indicator.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(indicator.kind == .preFail ? "Pre-fail · \(mode(indicator))" : "Life-span · \(mode(indicator))")
                        .font(.system(size: 10))
                        .foregroundStyle(DiagnosticTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rawValue(for: indicator))
                        .lineLimit(1)
                    if let delta = indicator.rawDelta, delta != 0 {
                        Text(delta > 0 ? "[+\(delta)]" : "[\(delta)]")
                            .font(.system(size: 10))
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                }
                .font(.system(size: 11))
                .frame(width: 102, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    if let current = indicator.current { Text("Current:  \(current)") }
                    if let worst = indicator.worst { Text("Worst:  \(worst)") }
                    if let threshold = indicator.threshold { Text("Threshold:  \(threshold)") }
                }
                .font(.system(size: 10))
                .foregroundStyle(DiagnosticTheme.muted)
                .frame(width: 112, alignment: .leading)
                HStack(spacing: 5) {
                    if let rating = indicator.rating {
                        DiagnosticBar(value: rating, color: IndicatorStyle.color(indicator.status))
                            .frame(width: 74)
                        Text("\(Int(rating))%")
                            .monospacedDigit()
                            .frame(width: 31, alignment: .trailing)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(indicator.status.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IndicatorStyle.color(indicator.status))
                        .frame(width: 39, alignment: .trailing)
                }
                .font(.system(size: 10))
                .frame(width: 158, alignment: .leading)
            }
            .foregroundStyle(DiagnosticTheme.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 51)
            .background(selected ? DiagnosticTheme.selection.opacity(0.7) : (index.isMultiple(of: 2) ? DiagnosticTheme.row : DiagnosticTheme.rowAlternate))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(indicator.id), \(indicator.name), \(indicator.rawDisplay), \(indicator.status.title)")
    }

    private func inspector(_ indicator: HealthIndicator) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(indicator.name).font(.system(size: 13, weight: .semibold))
            Text(indicator.explanation)
                .font(.system(size: 11))
                .foregroundStyle(DiagnosticTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel)
        .overlay(alignment: .top) { DiagnosticTheme.line.frame(height: 1) }
    }

    private func mode(_ indicator: HealthIndicator) -> String {
        switch indicator.updateMode {
        case .online: "online"
        case .offline: "offline"
        case .unknown: "update mode unknown"
        }
    }

    private func rawValue(for indicator: HealthIndicator) -> String {
        if indicator.name == "Power On Hours", let hours = drive.powerOnHours {
            return "\(hours) hours"
        }
        return indicator.rawDisplay
    }
}
