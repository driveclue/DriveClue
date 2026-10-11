import Charts
import DriveClueCore
import SwiftUI

enum TypeFilter: String, CaseIterable, Identifiable {
    case any = "Any Type"
    case preFail = "Pre-Fail"
    case lifeSpan = "Life-Span"
    var id: String { rawValue }
}

enum IndicatorSort: String, CaseIterable, Identifiable {
    case id = "ID"
    case name = "Name"
    case raw = "Raw Value"
    case value = "Value"
    case status = "Status"
    var id: String { rawValue }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case any = "Any Status"
    case ok = "OK"
    case warning = "Warning"
    case failing = "Failing"
    case failed = "Failed"
    var id: String { rawValue }
}

struct IndicatorsView: View {
    @Bindable var model: AppModel
    var drive: DriveSnapshot

    @State private var hoveredIndicatorID: Int?
    @FocusState private var searchFieldFocused: Bool

    private var rows: [HealthIndicator] {
        let filtered = drive.indicators.filter { indicator in
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
        return filtered.sorted(by: sorted)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            columnHeader
            if rows.isEmpty {
                ContentUnavailableView("No matching indicators", systemImage: "line.3.horizontal.decrease.circle", description: Text("Change a filter or search term to see indicators."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            if let indicator = drive.indicators.first(where: { $0.id == model.selectedIndicatorID }) {
                inspector(indicator)
            }
        }
        .background(DiagnosticTheme.background)
    }

    private var table: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, indicator in
                        indicatorRow(indicator, index: index)
                            .id(indicator.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .overlay(alignment: .topLeading) {
                if !searchFieldFocused {
                    Group {
                        Button("Next indicator") { moveSelection(1, proxy: proxy) }
                            .keyboardShortcut(.downArrow, modifiers: [])
                        Button("Previous indicator") { moveSelection(-1, proxy: proxy) }
                            .keyboardShortcut(.upArrow, modifiers: [])
                    }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }
        }
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
                .focused($searchFieldFocused)
                .frame(width: 190)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background(DiagnosticTheme.panel)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            sortHeader("ID", column: .id, width: 27)
            sortHeader("NAME", column: .name, width: nil)
            sortHeader("RAW VALUE", column: .raw, width: 102)
            sortHeader("VALUE", column: .value, width: 112)
            sortHeader("STATUS", column: .status, width: 158)
        }
        .diagnosticTableHeader()
    }

    private func sortHeader(_ title: String, column: IndicatorSort, width: CGFloat?) -> some View {
        let active = model.indicatorSort == column
        return Button {
            if active {
                model.sortAscending.toggle()
            } else {
                model.indicatorSort = column
                model.sortAscending = true
            }
        } label: {
            Group {
                if let width {
                    headerLabel(title, active: active).frame(width: width, alignment: .leading)
                } else {
                    headerLabel(title, active: active).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Click to reverse the sort order" : "Sort by \(column.rawValue.lowercased())")
        .accessibilityLabel("Sort \(active && model.sortAscending ? "descending" : "ascending") by \(column.rawValue)")
    }

    private func headerLabel(_ title: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
            if active {
                Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DiagnosticTheme.cyan)
            }
        }
    }

    private func indicatorRow(_ indicator: HealthIndicator, index: Int) -> some View {
        let selected = model.selectedIndicatorID == indicator.id
        let hovered = hoveredIndicatorID == indicator.id
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
            .background(rowBackground(selected: selected, hovered: hovered, index: index))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredIndicatorID = hovering ? indicator.id : nil
        }
        .help(hint(for: indicator))
        .accessibilityLabel("\(indicator.id), \(indicator.name), \(indicator.rawDisplay), \(indicator.status.title)")
    }

    private func rowBackground(selected: Bool, hovered: Bool, index: Int) -> Color {
        if selected { return DiagnosticTheme.selection.opacity(0.7) }
        if hovered { return DiagnosticTheme.row.opacity(1.25) }
        return index.isMultiple(of: 2) ? DiagnosticTheme.row : DiagnosticTheme.rowAlternate
    }

    private func inspector(_ indicator: HealthIndicator) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(indicator.name).font(.system(size: 13, weight: .semibold))
            Text(indicator.explanation)
                .font(.system(size: 11))
                .foregroundStyle(DiagnosticTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            IndicatorHistoryPanel(driveID: drive.id, indicator: indicator, store: model.history)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticTheme.panel)
        .overlay(alignment: .top) { DiagnosticTheme.line.frame(height: 1) }
    }

    // MARK: Sorting

    private func sorted(_ lhs: HealthIndicator, _ rhs: HealthIndicator) -> Bool {
        let order: ComparisonResult
        switch model.indicatorSort {
        case .id:
            order = compare(lhs.id, rhs.id)
        case .name:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .raw:
            order = compare(lhs.raw, rhs.raw)
        case .value:
            order = compare(lhs.current ?? lhs.worst, rhs.current ?? rhs.worst)
        case .status:
            order = compare(lhs.status.rank, rhs.status.rank)
        }
        if order == .orderedSame { return lhs.id < rhs.id }
        return model.sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        case let (left?, right?): compare(left, right)
        }
    }

    private func moveSelection(_ step: Int, proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex { $0.id == model.selectedIndicatorID } ?? (step > 0 ? -1 : 0)
        let nextIndex = min(max(currentIndex + step, 0), rows.count - 1)
        let target = rows[nextIndex]
        model.selectedIndicatorID = target.id
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    // MARK: Interactive help hints

    private func hint(for indicator: HealthIndicator) -> String {
        var lines = [indicator.explanation]
        if let rating = indicator.rating {
            let percent = Int(rating)
            switch indicator.status {
            case .ok: lines.append("The normalized value keeps \(percent)% of its healthy range above the failure threshold.")
            case .warning, .failing: lines.append("Only \(percent)% of the healthy range remains above the failure threshold.")
            case .failed: lines.append("The value reached its failure threshold.")
            }
        }
        lines.append("Recorded history and more detail appear in the panel below when selected.")
        return lines.joined(separator: "\n")
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

/// Chart and 30-day trend of one indicator's recorded values, shown in the inspector.
private struct IndicatorHistoryPanel: View {
    var driveID: String
    var indicator: HealthIndicator
    var store: HistoryStore

    @State private var samples: [IndicatorSample] = []
    @State private var trend: IndicatorTrend?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recorded history")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let trend {
                    Text(trendDescription(trend))
                        .font(.system(size: 11))
                        .foregroundStyle(trend.change > 0 && indicator.status != .ok ? DiagnosticTheme.amber : DiagnosticTheme.muted)
                }
            }
            if samples.count >= 2 {
                Chart(samples) { sample in
                    if let raw = sample.raw {
                        LineMark(x: .value("Checked", sample.takenAt), y: .value("Raw value", raw))
                            .foregroundStyle(DiagnosticTheme.cyan)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(compactNumber(number))
                            }
                        }
                    }
                }
                .frame(height: 84)
            } else {
                Text("DriveClue records a point each time it checks this drive. A trend line appears after a few saved checks.")
                    .font(.system(size: 11))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
        }
        .padding(.top, 5)
        .task(id: indicator.id) {
            samples = store.indicatorSamples(driveID: driveID, indicatorID: indicator.id)
            trend = store.indicatorTrend(driveID: driveID, indicatorID: indicator.id, days: 30)
        }
    }

    /// Compact axis labels (1.5M instead of scientific notation) for large raw counters.
    private func compactNumber(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return "\(Int(value))"
    }

    private func trendDescription(_ trend: IndicatorTrend) -> String {
        guard trend.change != 0 else { return "No change in the last 30 days" }
        let magnitude = ByteFormat.decimal(UInt64(abs(trend.change)))
        let changeText = trend.change > 0 ? "+\(magnitude)" : "-\(magnitude)"
        let span = max(Int(trend.spanDays.rounded()), 1)
        return "\(changeText) over \(span) day\(span == 1 ? "" : "s") of saved checks"
    }
}
