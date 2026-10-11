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
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(drive.statistics) { section in
                            StatisticsSectionCard(section: section)
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

/// One boxed statistics card rendered as a widget display: large gauges for
/// percentage and temperature entries, compact tiles for the remaining counts.
private struct StatisticsSectionCard: View {
    let section: StatSection

    private let gaugeColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private func tileColumns(_ count: Int) -> [GridItem] {
        // Two tiles read best side by side; long rows of numbers compact
        // three-across instead.
        let columns = count > 4 ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    private var isPercent: (StatEntry) -> Bool { { $0.value.trimmingCharacters(in: .whitespaces).hasSuffix("%") } }

    private var gaugeEntries: [StatEntry] {
        section.entries.filter { isPercent($0) || $0.name.lowercased().contains("temperature") }
    }

    private var countEntries: [StatEntry] {
        let gauges = Set(gaugeEntries.map(\.id))
        return section.entries.filter { !gauges.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionHeader(title: section.title, symbol: "tablecells", tint: sectionTint)
                Spacer(minLength: 12)
                Text("\(section.entries.count) \(section.entries.count == 1 ? "ENTRY" : "ENTRIES")")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            if !gaugeEntries.isEmpty {
                LazyVGrid(columns: gaugeColumns, spacing: 12) {
                    ForEach(gaugeEntries) { entry in
                        if isPercent(entry) {
                            StatGauge(name: entry.name, value: entry.value)
                        } else {
                            StatTemperatureGauge(name: entry.name, value: entry.value)
                        }
                    }
                }
                .padding(.top, 6)
            }
            if !countEntries.isEmpty {
                LazyVGrid(columns: tileColumns(countEntries.count), spacing: 12) {
                    ForEach(countEntries) { entry in
                        StatCountCard(name: entry.name, value: entry.value)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(DiagnosticTheme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var sectionTint: Color {
        let key = section.title.lowercased()
        if key.contains("temperature") { return DiagnosticTheme.orange }
        if key.contains("solid state") { return DiagnosticTheme.green }
        return DiagnosticTheme.cyan
    }
}

/// Large ring gauge for a percentage statistic, with the value in the center
/// and the sweep animating in from zero when the view appears.
private struct StatGauge: View {
    let name: String
    let value: String

    @State private var drawn = false

    private var percent: Double { statPercent(value) ?? 0 }
    private var color: Color { statisticColor(name: name, value: value) }
    private var number: String { statNumberParts(value).number }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.32), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: drawn ? percent / 100 : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(number)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(color)
                    Text("%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(DiagnosticTheme.muted)
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 112, height: 112)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DiagnosticTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .onAppear { drawn = true }
        .animation(.easeOut(duration: 0.7).delay(0.15), value: drawn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(number) percent")
    }
}

/// Ring gauge for a temperature statistic, scaled 0–100 °C, with the value
/// in the center and a status tag ("Good", "Caution", …) under the label.
private struct StatTemperatureGauge: View {
    let name: String
    let value: String

    @State private var drawn = false

    private var celsius: Int { numericPart(value) ?? 0 }
    private var band: (label: String, color: Color) { temperatureBand(celsius) }
    private var number: String { statNumberParts(value).number }
    private var unit: String { statNumberParts(value).unit ?? "°C" }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.32), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: drawn ? Double(min(max(celsius, 0), 100)) / 100 : 0)
                    .stroke(band.color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(number)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(band.color)
                    Text(unit)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(DiagnosticTheme.muted)
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 112, height: 112)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DiagnosticTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(band.label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(band.color, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .onAppear { drawn = true }
        .animation(.easeOut(duration: 0.7).delay(0.15), value: drawn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(number) degrees celsius, \(band.label)")
    }
}

/// Compact tile for the non-gauge counts of a widget section.
private struct StatCountCard: View {
    let name: String
    let value: String

    private var color: Color { statisticColor(name: name, value: value) }
    private var parts: (number: String, unit: String?) { statNumberParts(value) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color.opacity(0.9))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(compactCount(parts.number))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(color)
                    if let unit = parts.unit {
                        Text(unit)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                }
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .help("\(name): \(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(value)")
    }

    private var icon: String {
        let key = name.lowercased()
        if key.contains("shutdown") { return "power" }
        if key.contains("error") { return "memorychip" }
        if key.contains("hour") { return "clock.fill" }
        if key.contains("cycle") { return "arrow.triangle.2.circlepath" }
        if key.contains("command") {
            return key.contains("write") ? "arrow.up.circle.dotted" : "arrow.down.circle.dotted"
        }
        if key.contains("write") || key.contains("written") { return "arrow.up.circle.fill" }
        if key.contains("read") { return "arrow.down.circle.fill" }
        return "number"
    }
}

/// Thermal bands for drive temperatures, aligned with common NVMe practice:
/// drives run normally up to ~65 °C, warn (WCTEMP) around 70 °C, and reach
/// the critical composite threshold (CCTEMP) near 80 °C.
private func temperatureBand(_ celsius: Int) -> (label: String, color: Color) {
    if celsius <= 0 { return ("Cold", DiagnosticTheme.teal) }
    if celsius < 30 { return ("Cool", DiagnosticTheme.cyan) }
    if celsius < 65 { return ("Good", DiagnosticTheme.green) }
    if celsius < 80 { return ("Caution", DiagnosticTheme.amber) }
    return ("Critical", DiagnosticTheme.red)
}

/// Compacts very large counts ("31,887,064,332" → "31.9B") so tiles stay
/// readable; the exact value stays available through the tooltip and
/// accessibility label.
private func compactCount(_ text: String) -> String {
    let cleaned = text.filter { $0.isNumber }
    guard cleaned.count >= 7, let n = Double(cleaned) else { return text }
    if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
    return String(format: "%.1fM", n / 1_000_000)
}

/// Value color for a statistics entry. Health-related stats reuse the
/// dashboard's band colors; every other value uses the cyan data accent.
private func statisticColor(name: String, value: String) -> Color {
    let key = name.lowercased()
    if key.contains("temperature"), let celsius = numericPart(value) {
        return temperatureBand(celsius).color
    }
    if key.contains("percentage used") || key.contains("endurance indicator"), let used = numericPart(value) {
        // Inverse of the dashboard's 80/50 health bands.
        let lifeLeft = 100 - used
        if lifeLeft >= 80 { return DiagnosticTheme.green }
        if lifeLeft >= 50 { return DiagnosticTheme.amber }
        return DiagnosticTheme.red
    }
    if key.contains("available spare"), let spare = numericPart(value) {
        if spare >= 20 { return DiagnosticTheme.green }
        if spare >= 10 { return DiagnosticTheme.amber }
        return DiagnosticTheme.red
    }
    if key.contains("media") && key.contains("error") {
        return (numericPart(value) ?? 1) == 0 ? DiagnosticTheme.green : DiagnosticTheme.red
    }
    return DiagnosticTheme.cyan
}

private func numericPart(_ value: String) -> Int? {
    let cleaned = value.filter { $0.isNumber || $0 == "." }
    guard cleaned.contains(where: \.isNumber), let parsed = Double(cleaned) else { return nil }
    return Int(parsed.rounded())
}

private func statPercent(_ value: String) -> Double? {
    guard value.trimmingCharacters(in: .whitespaces).hasSuffix("%") else { return nil }
    let cleaned = value.filter { $0.isNumber || $0 == "." }
    guard cleaned.contains(where: \.isNumber), let parsed = Double(cleaned) else { return nil }
    return min(max(parsed, 0), 100)
}

private func statNumberParts(_ value: String) -> (number: String, unit: String?) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.hasSuffix("%") {
        return (String(trimmed.dropLast()), "%")
    }
    guard let space = trimmed.lastIndex(of: " ") else { return (trimmed, nil) }
    let head = String(trimmed[..<space])
    let tail = String(trimmed[trimmed.index(after: space)...])
    // Only treat a short digit-free tail as a unit ("TB", "°C"), never prose.
    if !head.isEmpty, tail.count <= 6, !tail.contains(where: \.isNumber) {
        return (head, tail)
    }
    return (trimmed, nil)
}

