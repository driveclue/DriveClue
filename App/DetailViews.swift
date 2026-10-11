import DriveClueCore
import SwiftUI

struct SelfTestsView: View {
    @Bindable var model: AppModel
    var drive: DriveSnapshot
    @State private var volumeBSD = ""
    @State private var testSize: DiskBenchmarkSize = .oneGB
    @State private var passes: DiskBenchmarkPasses = .four

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ataSelfTestPanel
                benchmarkPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiagnosticTheme.background)
        .onAppear { selectDefaultVolume() }
        .onChange(of: drive.id) { selectDefaultVolume() }
    }

    @ViewBuilder
    private var ataSelfTestPanel: some View {
        if drive.transport == .ata {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "ATA S.M.A.R.T. Self-test", symbol: "stethoscope", tint: DiagnosticTheme.purple)
                Text("Runs the drive’s built-in diagnostic. This is separate from the volume read/write benchmark below.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiagnosticTheme.muted)
                if drive.supportsSelfTest {
                    HStack(spacing: 10) {
                        Button("Run Short Test") { Task { await model.startSelfTest(extended: false) } }
                        Button("Run Full Test") { Task { await model.startSelfTest(extended: true) } }
                        if model.sleepAssertionHeld {
                            Label("Keeping Mac awake for full test", systemImage: "moon.zzz")
                                .foregroundStyle(DiagnosticTheme.muted)
                        }
                    }
                    .disabled(drive.selfTestProgress != nil)
                    if let progress = drive.selfTestProgress {
                        ProgressView(value: Double(progress.percent), total: 100) {
                            Text("Self-test running · \(progress.percent)% complete")
                        }
                        if let minutes = progress.remainingMinutes {
                            Text("Approximately \(minutes) minutes remaining")
                                .font(.caption)
                                .foregroundStyle(DiagnosticTheme.muted)
                        }
                        Text("DriveClue cannot cancel an ATA self-test on this device. Check again to update progress.")
                            .font(.caption)
                            .foregroundStyle(DiagnosticTheme.muted)
                    }
                } else {
                    Text(drive.selfTestUnavailableReason ?? "This drive does not advertise ATA self-tests.")
                        .foregroundStyle(DiagnosticTheme.muted)
                }
                if drive.selfTests.isEmpty {
                    Text("No self-test history reported by this drive.")
                        .font(.caption)
                        .foregroundStyle(DiagnosticTheme.muted)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("#").frame(width: 28, alignment: .leading)
                            Text("TEST").frame(width: 105, alignment: .leading)
                            Text("STATUS").frame(maxWidth: .infinity, alignment: .leading)
                            Text("POWER-ON HOURS").frame(width: 125, alignment: .trailing)
                            Text("FAILING LBA").frame(width: 120, alignment: .trailing)
                        }.diagnosticTableHeader()
                        ForEach(Array(drive.selfTests.enumerated()), id: \.element.id) { index, test in
                            HStack(spacing: 12) {
                                Text("\(test.id)").frame(width: 28, alignment: .leading)
                                Text(test.testType).frame(width: 105, alignment: .leading)
                                Text(test.status).frame(maxWidth: .infinity, alignment: .leading)
                                Text(test.powerOnHours.map(String.init) ?? "—").frame(width: 125, alignment: .trailing)
                                Text(test.failingLBA).frame(width: 120, alignment: .trailing)
                            }.diagnosticTableRow(index: index)
                        }
                    }
                }
            }
            .panel()
        }
    }

    private var benchmarkPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let running = model.benchmark, running.isRunning {
                Label("Running on \(running.volumeName) (\(running.driveID))", systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DiagnosticTheme.amber)
                    .accessibilityLabel("Benchmark running on \(running.volumeName)")
                if running.driveID != drive.id || running.volumeBSD != selectedVolume?.bsdName {
                    Text("The active benchmark is on another drive or volume. Stop it here before starting a new test.")
                        .font(.caption)
                        .foregroundStyle(DiagnosticTheme.muted)
                }
                Button("Stop Active Benchmark") { model.cancelBenchmark() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Stops the benchmark on \(running.volumeName)")
            }
            SectionHeader(title: "Read / Write benchmark", symbol: "chart.bar.fill", tint: DiagnosticTheme.cyan)
            Text("Sequential file throughput on a mounted volume. The default is four complete write/read rounds, with a Continuous option. The temporary test file is flushed, read without filesystem caching, and removed when finished.")
                .font(.system(size: 12))
                .foregroundStyle(DiagnosticTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            BenchmarkSectionCard(title: "TEST SETUP", symbol: "slider.horizontal.3", tint: DiagnosticTheme.cyan) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        if benchmarkVolumes.count > 1 {
                            Picker("Volume", selection: $volumeBSD) {
                                ForEach(benchmarkVolumes) { volume in
                                    Text(volume.name).tag(volume.bsdName)
                                }
                            }
                            .frame(width: 170)
                        } else if let volume = benchmarkVolumes.first {
                            Label(volume.name, systemImage: "externaldrive")
                                .foregroundStyle(DiagnosticTheme.text)
                        } else {
                            Label("No writable mounted volume", systemImage: "externaldrive.badge.xmark")
                                .foregroundStyle(DiagnosticTheme.muted)
                        }
                        Picker("Test size", selection: $testSize) {
                            ForEach(DiskBenchmarkSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .frame(width: 140)
                        Picker("Passes", selection: $passes) {
                            ForEach(DiskBenchmarkPasses.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .frame(width: 175)
                        Spacer()
                        if model.benchmark?.isRunning == true {
                            Label("Benchmark running on \(model.benchmark?.volumeName ?? "another volume")", systemImage: "waveform.path.ecg")
                                .foregroundStyle(DiagnosticTheme.amber)
                        } else {
                            Text("Press START to begin")
                                .foregroundStyle(DiagnosticTheme.muted)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if benchmarkState == nil {
                        Text("Use at least 512 MB for a useful result. The test writes only to its temporary file and needs the selected test size plus a small safety reserve free.")
                            .font(.caption)
                            .foregroundStyle(DiagnosticTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            BenchmarkSectionCard(title: "THROUGHPUT", symbol: "gauge.with.dots.needle.67percent", tint: DiagnosticTheme.green) {
                benchmarkReadout
            }

            if let state = benchmarkState {
                if state.volumeBSD != selectedVolume?.bsdName {
                    Text("Showing \(state.isRunning ? "active test" : "last result") for \(state.volumeName), not the selected volume.")
                        .font(.caption)
                        .foregroundStyle(DiagnosticTheme.amber)
                }
                BenchmarkSectionCard(title: "PROGRESS", symbol: "clock.arrow.circlepath", tint: DiagnosticTheme.amber) {
                    benchmarkProgress(state)
                }
                if let result = state.result {
                    benchmarkReport(result: result)
                }
            } else if let running = model.benchmark, running.isRunning {
                BenchmarkSectionCard(title: "ACTIVE BENCHMARK ON ANOTHER DRIVE", symbol: "clock.arrow.circlepath", tint: DiagnosticTheme.amber) {
                    benchmarkProgress(running)
                }
            }
        }
    }

    private func benchmarkProgress(_ state: DiskBenchmarkState) -> some View {
        let progress = state.progress
        let percent = Int(Double(progress.completedBytes) / Double(max(progress.totalBytes, 1)) * 100)
        let roundLabel = progress.totalRounds.map { "\(progress.phase.title) · round \(progress.round)/\($0)" } ?? "\(progress.phase.title) · round \(progress.round)"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Volume: \(state.volumeName) (\(state.volumeBSD)) · Drive: \(state.driveID)")
                .font(.caption.weight(.medium))
                .foregroundStyle(DiagnosticTheme.text)
            Text("Test folder: \(state.directoryPath)")
                .font(.caption)
                .foregroundStyle(DiagnosticTheme.muted)
                .textSelection(.enabled)
            ProgressView(value: Double(progress.completedBytes), total: Double(max(progress.totalBytes, 1))) {
                Text("\(roundLabel)… \(percent)%")
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.easeInOut(duration: 0.3), value: progress.round)
                    .animation(.easeInOut(duration: 0.25), value: progress.phase)
            }
            .tint(DiagnosticTheme.cyan)
            if let speed = progress.currentMBps {
                Text(String(format: "Current speed %.0f MB/s", speed))
                    .font(.caption)
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            if let error = state.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(DiagnosticTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var benchmarkReadout: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(spacing: 14) {
                BenchmarkThroughputBar(
                    title: "WRITE",
                    speed: benchmarkWriteSpeed,
                    maximum: benchmarkMaximum,
                    color: DiagnosticTheme.orange,
                    isActive: benchmarkPhase == .writing
                )
                BenchmarkThroughputBar(
                    title: "READ",
                    speed: benchmarkReadSpeed,
                    maximum: benchmarkMaximum,
                    color: DiagnosticTheme.green,
                    isActive: benchmarkPhase == .reading
                )
            }
            .frame(maxWidth: .infinity)

            Button(action: benchmarkAction) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.42))
                        .frame(width: 92, height: 92)
                        .overlay(Circle().stroke(DiagnosticTheme.cyan.opacity(0.78), lineWidth: 2))
                        .shadow(color: DiagnosticTheme.cyan.opacity(isBenchmarkRunning ? 0.44 : 0.18), radius: 12)
                    VStack(spacing: 3) {
                        Image(systemName: isBenchmarkRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isBenchmarkRunning ? DiagnosticTheme.amber : DiagnosticTheme.cyan)
                        Text(isBenchmarkRunning ? "STOP" : "START")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(DiagnosticTheme.text)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isBenchmarkRunning && (selectedVolume == nil || model.benchmark?.isRunning == true))
            .help(isBenchmarkRunning ? "Stop benchmark" : "Start benchmark")
            .accessibilityLabel(isBenchmarkRunning ? "Stop benchmark" : "Start benchmark")
        }
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 190)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var benchmarkVolumes: [VolumeInfo] {
        drive.volumes.filter { $0.isUserFacing && $0.mountPath != nil && $0.role != "System" }
    }

    private var selectedVolume: VolumeInfo? {
        benchmarkVolumes.first { $0.bsdName == volumeBSD } ?? benchmarkVolumes.first
    }

    private var benchmarkState: DiskBenchmarkState? {
        guard let state = model.benchmark, state.driveID == drive.id else { return nil }
        return state
    }

    private var isBenchmarkRunning: Bool { benchmarkState?.isRunning == true }

    private func selectDefaultVolume() {
        if !benchmarkVolumes.contains(where: { $0.bsdName == volumeBSD }) {
            volumeBSD = benchmarkVolumes.first?.bsdName ?? ""
        }
    }

    private func startBenchmark() {
        guard let volume = selectedVolume else { return }
        model.startBenchmark(drive: drive, volume: volume, testSize: testSize, passes: passes)
    }

    private func benchmarkAction() {
        if isBenchmarkRunning {
            model.cancelBenchmark()
        } else {
            startBenchmark()
        }
    }

    private var benchmarkPhase: DiskBenchmarkPhase? {
        benchmarkState?.progress.phase
    }

    private var benchmarkWriteSpeed: Double {
        guard let state = benchmarkState else { return 0 }
        return state.writeSpeed ?? 0
    }

    private var benchmarkReadSpeed: Double {
        guard let state = benchmarkState else { return 0 }
        return state.readSpeed ?? 0
    }

    private var benchmarkMaximum: Double {
        let peak = max(benchmarkWriteSpeed, benchmarkReadSpeed)
        let stepped = (peak * 1.25 / 500).rounded(.up) * 500
        return max(1_000, stepped)
    }
}

/// Titled section card shared by the benchmark controls and the report:
/// palette icon + tracked uppercase caption over a bordered panel.
struct BenchmarkSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tint, .white.opacity(0.9))
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(DiagnosticTheme.text)
            }
            content()
        }
        .padding(12)
        .background(DiagnosticTheme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct BenchmarkReport: View {
    let result: DiskBenchmarkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BenchmarkSectionCard(title: "FINAL RESULT", symbol: "flag.checkered", tint: DiagnosticTheme.orange) {
                finalResult
            }
            Text("Measured sequential file throughput; results vary by workload and filesystem.")
                .font(.caption)
                .foregroundStyle(DiagnosticTheme.muted)
        }
    }

    private var roundsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("ROUND").frame(width: 70, alignment: .leading)
                Text("WRITE MB/s").frame(width: 100, alignment: .trailing)
                Text("READ MB/s").frame(width: 100, alignment: .trailing)
                Text("DURATION").frame(maxWidth: .infinity, alignment: .trailing)
            }.diagnosticTableHeader()
            ForEach(result.rounds) { round in
                HStack(spacing: 8) {
                    Text("#\(round.round)").frame(width: 70, alignment: .leading)
                    Text(String(format: "%.1f", round.writeMBps))
                        .foregroundStyle(DiagnosticTheme.orange)
                        .frame(width: 100, alignment: .trailing)
                    Text(String(format: "%.1f", round.readMBps))
                        .foregroundStyle(DiagnosticTheme.green)
                        .frame(width: 100, alignment: .trailing)
                    Text(String(format: "%.2fs + %.2fs", round.writeDuration, round.readDuration))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.diagnosticTableRow(index: round.round - 1)
            }
        }
    }

    private var finalResult: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                resultMetric(title: "WRITE AVERAGE", value: result.writeMBps, color: DiagnosticTheme.orange)
                resultMetric(title: "READ AVERAGE", value: result.readMBps, color: DiagnosticTheme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ROUNDS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DiagnosticTheme.muted)
                    Text("\(result.rounds.count)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(DiagnosticTheme.cyan)
                    Text(ByteFormat.bytes(result.testSize) + " each")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DiagnosticTheme.muted)
                }
            }
            roundsTable
        }
    }

    private func resultMetric(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(DiagnosticTheme.muted)
            Text(String(format: "%.1f", value))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text("MB/s")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DiagnosticTheme.muted)
        }
    }

}

private extension SelfTestsView {
    func benchmarkReport(result: DiskBenchmarkResult) -> some View {
        BenchmarkReport(result: result)
    }
}

struct DiagnosticNotice: View {
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
            .panel()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
