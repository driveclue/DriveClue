import XCTest
@testable import DriveClueCore

final class ScoringTests: XCTestCase {
    func testReallocatedSectorsStayHighButFailing() {
        let attribute = RawAttribute(id: 5, flags: 0x03, current: 100, worst: 100, threshold: 10, raw: 3)
        let scored = DriveScorer.score(attribute: attribute, model: "Samsung SSD", isSSD: true)
        XCTAssertEqual(scored.status, .failing)
        XCTAssertGreaterThan(scored.rating ?? 0, 90)
        XCTAssertEqual(scored.name, "Reallocated Sector Count")
    }

    func testThresholdFailure() {
        let attribute = RawAttribute(id: 5, flags: 0x03, current: 5, worst: 5, threshold: 10, raw: 40)
        let scored = DriveScorer.score(attribute: attribute, model: "ST1000", isSSD: false)
        XCTAssertEqual(scored.status, .failed)
        XCTAssertEqual(scored.rating, 0)
    }

    func testCRCIsWarningNotDriveDeath() {
        let attribute = RawAttribute(id: 199, flags: 0x32, current: 200, worst: 200, threshold: 0, raw: 7)
        let scored = DriveScorer.score(attribute: attribute, model: "Samsung SSD 830", isSSD: true)
        XCTAssertEqual(scored.status, .warning)
        XCTAssertFalse(scored.countsTowardHealth)
    }

    func testNVMeLifeAndMediaError() {
        let numbers = NVMeLog.NVMeNumbers(
            temperatureCelsius: 42,
            availableSpare: 100,
            spareThreshold: 10,
            percentageUsed: 3,
            criticalWarning: 0,
            dataUnitsRead: 10,
            dataUnitsWritten: 20,
            powerCycles: 80,
            powerOnHours: 400,
            unsafeShutdowns: 1,
            mediaErrors: 2,
            errorLogEntries: 2
        )
        let indicators = NVMeLog.indicators(raw: numbers)
        let summary = DriveScorer.summarize(indicators, isSSD: true)
        XCTAssertEqual(summary.ssdLife, 97)
        XCTAssertEqual(summary.status, .failing)
        XCTAssertEqual(indicators.first { $0.id == 11 }?.status, .failing)
    }

    func testAttributeParserReadsTwelveByteRecords() {
        var data = Data(repeating: 0, count: 512)
        data[0] = 1
        data[2] = 5
        data[3] = 0x03
        data[5] = 100
        data[6] = 100
        data[7] = 4
        var thresholds = Data(repeating: 0, count: 512)
        thresholds[2] = 5
        thresholds[3] = 10
        let parsed = ATAParser.attributes(smartData: data, thresholds: thresholds)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, 5)
        XCTAssertEqual(parsed[0].raw, 4)
        XCTAssertEqual(parsed[0].threshold, 10)
    }

    func testSelfTestLogAndErrorLog() {
        var log = Data(repeating: 0, count: 512)
        log[0] = 1
        log[2] = 1
        log[3] = 0
        log[4] = 10
        log[508] = 1
        let tests = ATAParser.selfTests(log: log)
        XCTAssertEqual(tests.first?.testType, "Short offline")
        XCTAssertEqual(tests.first?.status, "Completed without error")
        XCTAssertEqual(tests.first?.powerOnHours, 10)

        var errors = Data(repeating: 0, count: 512)
        errors[1] = 1
        errors[452] = 1
        errors[2 + 61] = 0x40
        errors[2 + 88] = 12
        errors[2 + 5 * 12 + 7] = 0x25
        let parsed = ATAParser.errors(log: errors)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].summary.contains("UNC"))
        XCTAssertTrue(parsed[0].priorCommand.contains("Read DMA"))
    }

    func testDeviceStatisticFlags() {
        var page = Data(repeating: 0, count: 512)
        page[2] = 1
        page[0x008 + 7] = 0xC0
        page[0x008] = 9
        let value = ATAParser.statisticValue(page, offset: 0x008)
        XCTAssertEqual(value, 9)
        let sections = ATAParser.statistics(log: page)
        XCTAssertEqual(sections.first?.entries.first?.name, "Lifetime Power-on Resets")
    }

    func testReportAndFreeSpace() {
        let drive = sampleDrive()
        let text = ReportBuilder.text(drives: [drive])
        XCTAssertTrue(text.contains("Samsung SSD"))
        let csv = ReportBuilder.csv(drives: [drive])
        XCTAssertTrue(csv.contains("Reallocated"))
        let alerts = FreeSpaceMonitor.alerts(drives: [drive], thresholds: ["disk3s5": 20])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].freePercent, 10)
    }

    func testHistoryDeltas() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("driveclue-test-\(UUID().uuidString).sqlite")
        let store = HistoryStore(url: url)
        var drive = sampleDrive()
        store.record([drive])
        drive.indicators[0].raw = 8
        let updated = store.applyDeltas([drive])
        XCTAssertEqual(updated[0].indicators[0].rawDelta, 5)
        store.record([updated[0]])
        XCTAssertFalse(store.samples(driveID: drive.id).isEmpty)
        store.addEvent(driveID: drive.id, kind: "status", message: "Warning")
        XCTAssertEqual(store.events(driveID: drive.id).first?.message, "Warning")
    }

    func testDiagnosisMentionsCable() {
        var drive = sampleDrive()
        drive.indicators[0].id = 199
        drive.indicators[0].name = "UDMA CRC Error Count"
        drive.indicators[0].status = .warning
        let lines = Diagnosis.lines(for: drive)
        XCTAssertTrue(lines.contains { $0.contains("cable") })
    }

    private func sampleDrive() -> DriveSnapshot {
        let indicator = HealthIndicator(
            id: 5,
            name: "Reallocated Sector Count",
            kind: .preFail,
            updateMode: .online,
            raw: 3,
            rawDisplay: "3",
            rawIsApproximate: false,
            current: 100,
            worst: 100,
            threshold: 10,
            rating: 100,
            status: .failing,
            explanation: "Spare sectors were used.",
            isImportant: true,
            affectsPerformance: false,
            countsTowardHealth: true
        )
        return DriveSnapshot(
            id: "SERIAL",
            bsdName: "disk0",
            volumes: [VolumeInfo(name: "Data", bsdName: "disk3s5", mountPath: "/", role: "Data", totalBytes: 100, availableBytes: 10, purgeableBytes: 0)],
            transport: .ata,
            model: "Samsung SSD 830",
            modelFamily: "Samsung based SSDs",
            serial: "SERIAL",
            firmware: "1",
            wwn: nil,
            capacityBytes: 512_000_000_000,
            sectorSize: 512,
            powerOnHours: 10,
            powerCycleCount: 4,
            temperatureCelsius: 35,
            temperatureMin: nil,
            temperatureMax: nil,
            recommendedTempMin: 0,
            recommendedTempMax: 70,
            overTemperatureMinutes: nil,
            underTemperatureMinutes: nil,
            indicators: [indicator],
            overallHealth: 100,
            healthBand: .good,
            performance: nil,
            performanceBand: nil,
            ssdLife: 99,
            ssdLifeBand: .good,
            smartStatus: .failing,
            issueCount: 1,
            isSSD: true,
            supportsSelfTest: true,
            selfTestUnavailableReason: nil,
            capabilities: [],
            errors: [],
            statistics: [],
            selfTests: [],
            selfTestProgress: nil,
            shortTestMinutes: 2,
            extendedTestMinutes: 20,
            ioErrorCount: 0,
            bytesWritten: 1000,
            checkedAt: Date(),
            readError: nil,
            interconnect: "SATA",
            location: "Internal"
        )
    }
}
