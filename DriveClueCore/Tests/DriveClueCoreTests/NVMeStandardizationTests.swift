import XCTest
@testable import DriveClueCore

/// Coverage for the standard NVMe health-log presentation: DriveDX-compatible
/// indicator numbering, honest temperature normalization, wear kept out of the
/// overall health rating, and the history-side worst value and ID migration.
final class NVMeStandardizationTests: XCTestCase {
    private func healthyNumbers() -> NVMeLog.NVMeNumbers {
        NVMeLog.NVMeNumbers(
            temperatureCelsius: 42,
            availableSpare: 100,
            spareThreshold: 1,
            percentageUsed: 11,
            criticalWarning: 0,
            dataUnitsRead: 877_931_172,
            dataUnitsWritten: 583_746_515,
            powerCycles: 469,
            powerOnHours: 8_687,
            unsafeShutdowns: 20,
            mediaErrors: 0,
            errorLogEntries: 0,
            controllerBusyMinutes: 0,
            warningTempMinutes: 0,
            criticalTempMinutes: 0
        )
    }

    func testStandardIndicatorIDsAndOrder() {
        let indicators = NVMeLog.indicators(raw: healthyNumbers())
        XCTAssertEqual(indicators.map(\.id), [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17])
        XCTAssertEqual(indicators.first { $0.id == 8 }?.name, "Host Read Commands")
        XCTAssertEqual(indicators.first { $0.id == 9 }?.name, "Host Write Commands")
        XCTAssertEqual(indicators.first { $0.id == 10 }?.name, "Controller Busy Time")
        XCTAssertEqual(indicators.first { $0.id == 11 }?.name, "Power Cycles")
        XCTAssertEqual(indicators.first { $0.id == 12 }?.name, "Power On Hours")
        XCTAssertEqual(indicators.first { $0.id == 13 }?.name, "Unsafe Shutdowns")
        XCTAssertEqual(indicators.first { $0.id == 14 }?.name, "Media and Data Integrity Errors")
        XCTAssertEqual(indicators.first { $0.id == 15 }?.name, "Error Information Log Entries")
        XCTAssertEqual(indicators.first { $0.id == 16 }?.name, "Warning Composite Temperature Time")
        XCTAssertEqual(indicators.first { $0.id == 17 }?.name, "Critical Composite Temperature Time")
    }

    func testTemperatureNormalizationMatchesDriveDX() {
        // 42 °C → normalized 58 against threshold 30, i.e. 40% headroom.
        let temp = NVMeLog.indicators(raw: healthyNumbers()).first { $0.id == 2 }!
        XCTAssertEqual(temp.current, 58)
        XCTAssertEqual(temp.threshold, 30)
        XCTAssertEqual((temp.rating ?? 0).rounded(), 40)
        XCTAssertEqual(temp.status, .ok)
    }

    func testOverallHealthDecoupledFromWear() {
        // 11% endurance used must lower SSD lifetime, not the overall health rating.
        let summary = DriveScorer.summarize(NVMeLog.indicators(raw: healthyNumbers()), isSSD: true)
        XCTAssertEqual(summary.health, 100)
        XCTAssertEqual(summary.ssdLife, 89)
        XCTAssertEqual(summary.status, .ok)
        XCTAssertEqual(summary.issues, 0)
    }

    func testCounterRowsUseHealthyConvention() {
        let indicators = NVMeLog.indicators(raw: healthyNumbers())
        for id in [6, 7, 8, 9, 10, 11, 12, 13, 16, 17] {
            let row = indicators.first { $0.id == id }!
            XCTAssertEqual(row.rating, 100, "indicator \(id)")
            XCTAssertEqual(row.current, 100, "indicator \(id)")
            XCTAssertEqual(row.status, .ok, "indicator \(id)")
        }
    }

    func testDataUnitsDisplayShowsRawAndBytes() {
        let written = NVMeLog.indicators(raw: healthyNumbers()).first { $0.id == 7 }!
        XCTAssertTrue(written.rawDisplay.contains("583,746,515"), written.rawDisplay)
        XCTAssertTrue(written.rawDisplay.contains("TB"), written.rawDisplay)
    }

    func testMediaErrorsStayFailingAtNewID() {
        var numbers = healthyNumbers()
        numbers.mediaErrors = 2
        let indicators = NVMeLog.indicators(raw: numbers)
        XCTAssertEqual(indicators.first { $0.id == 14 }?.status, .failing)
        let summary = DriveScorer.summarize(indicators, isSSD: true)
        XCTAssertEqual(summary.status, .failing)
    }

    func testCriticalWarningStillFailsDrive() {
        var numbers = healthyNumbers()
        numbers.criticalWarning = 0x01
        let indicators = NVMeLog.indicators(raw: numbers)
        XCTAssertEqual(indicators.first { $0.id == 1 }?.status, .failed)
        XCTAssertEqual(DriveScorer.summarize(indicators, isSSD: true).status, .failed)
    }

    // MARK: History-side behavior

    private func makeStore() -> HistoryStore {
        HistoryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("driveclue-nvme-test-\(UUID().uuidString).sqlite"))
    }

    private func nvmeDrive(id: String, checkedAt: Date) -> DriveSnapshot {
        var snapshot = DriveSnapshot(id: id, bsdName: "disk0", transport: .nvme, serial: id, checkedAt: checkedAt)
        snapshot.indicators = NVMeLog.indicators(raw: healthyNumbers())
        return snapshot
    }

    func testWorstComesFromRecordedHistoryNotCurrentCopy() {
        let store = makeStore()
        let first = nvmeDrive(id: "NV1", checkedAt: Date(timeIntervalSinceNow: -7_200))
        let stampedFirst = store.applyDeltas([first])
        XCTAssertEqual(stampedFirst[0].indicators.first { $0.id == 2 }?.worst, 58)
        store.record(stampedFirst)

        var second = nvmeDrive(id: "NV1", checkedAt: Date())
        second.indicators[1].current = 50 // composite temperature rose to 50 °C
        let stampedSecond = store.applyDeltas([second])
        XCTAssertEqual(stampedSecond[0].indicators.first { $0.id == 2 }?.worst, 50)
    }

    func testATAWorstIsNeverOverwritten() {
        let store = makeStore()
        var drive = DriveSnapshot(id: "ATA1", bsdName: "disk1", transport: .ata, serial: "ATA1", checkedAt: Date())
        drive.indicators = [
            HealthIndicator(id: 5, name: "Reallocated Sector Count", kind: .preFail, updateMode: .online, raw: 3, rawDisplay: "3", current: 80, worst: 97, threshold: 10, rating: 70, status: .ok, explanation: "", isImportant: true, affectsPerformance: false, countsTowardHealth: true)
        ]
        let stamped = store.applyDeltas([drive])
        XCTAssertEqual(stamped[0].indicators[0].worst, 97)
    }

    func testNVMeIndicatorHistoryMigratesToStandardIDs() {
        let store = makeStore()
        // Simulate the pre-standardization layout on disk: rows saved under the old
        // app-specific IDs with raw values that cannot collide with fresh rows.
        // Recording them as .ata avoids triggering the NVMe migration, mirroring a
        // database written by the previous app version.
        let legacy: [(id: Int, raw: UInt64)] = [(8, 111), (9, 22), (10, 33), (11, 44), (12, 55)]
        var oldDrive = DriveSnapshot(id: "NVOLD", bsdName: "disk0", transport: .ata, serial: "NVOLD", checkedAt: Date(timeIntervalSinceNow: -7_200))
        oldDrive.indicators = legacy.map {
            HealthIndicator(id: $0.id, name: "Legacy \($0.id)", kind: .lifeSpan, updateMode: .online, raw: $0.raw, rawDisplay: "\($0.raw)", current: nil, worst: nil, threshold: nil, rating: nil, status: .ok, explanation: "", isImportant: false, affectsPerformance: false, countsTowardHealth: false)
        }
        store.record([oldDrive])

        // The new build reads the same NVMe drive with standard numbering: the saved
        // rows must be re-pointed once.
        store.record([nvmeDrive(id: "NVOLD", checkedAt: Date(timeIntervalSinceNow: -1_800))])

        func countRaw(_ indicatorID: Int, _ raw: UInt64) -> Int {
            store.indicatorSamples(driveID: "NVOLD", indicatorID: indicatorID).filter { $0.raw == Double(raw) }.count
        }
        XCTAssertEqual(countRaw(12, 111), 1, "old id 8 (hours) → 12")
        XCTAssertEqual(countRaw(11, 22), 1, "old id 9 (cycles) → 11")
        XCTAssertEqual(countRaw(13, 33), 1, "old id 10 (unsafe) → 13")
        XCTAssertEqual(countRaw(14, 44), 1, "old id 11 (media) → 14")
        XCTAssertEqual(countRaw(15, 55), 1, "old id 12 (error log) → 15")

        // The marker keeps the migration one-shot: another record must not re-remap
        // the freshly written standard rows.
        store.record([nvmeDrive(id: "NVOLD", checkedAt: Date())])
        XCTAssertEqual(countRaw(11, 22), 1)
        XCTAssertEqual(countRaw(12, 111), 1)
    }
}
