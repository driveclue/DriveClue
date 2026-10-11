import XCTest
@testable import DriveClueCore

final class HistoryStoreTests: XCTestCase {
    private func makeStore() -> (store: HistoryStore, url: URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString).sqlite")
        return (HistoryStore(url: url), url)
    }

    private func indicator(raw: UInt64?, current: Int?) -> HealthIndicator {
        HealthIndicator(
            id: 5,
            name: "Reallocated Sectors",
            kind: .preFail,
            updateMode: .online,
            raw: raw,
            rawDisplay: raw.map { "\($0)" } ?? "—",
            current: current,
            worst: 100,
            threshold: 36,
            rating: 90,
            status: .ok,
            explanation: "Test indicator",
            isImportant: true,
            affectsPerformance: false,
            countsTowardHealth: true
        )
    }

    private func makeDrive(
        id: String,
        checkedAt: Date,
        indicators: [HealthIndicator] = [],
        ssdLife: Double? = nil
    ) -> DriveSnapshot {
        DriveSnapshot(
            id: id,
            bsdName: "disk0",
            transport: .ata,
            model: "Test Drive",
            serial: id,
            indicators: indicators,
            ssdLife: ssdLife,
            isSSD: true,
            checkedAt: checkedAt
        )
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testFailedReadDoesNotReplaceValidHistoryOrIndicatorBaseline() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let start = Date()
        let valid = makeDrive(id: "SERIAL1", checkedAt: start, indicators: [indicator(raw: 100, current: 92)], ssdLife: 92)
        store.record([valid])

        var failed = makeDrive(id: "SERIAL1", checkedAt: start.addingTimeInterval(86400), indicators: [indicator(raw: 0, current: 0)], ssdLife: 0)
        failed.readError = "Read timed out"
        failed.overallHealth = 0
        failed.temperatureCelsius = 0
        failed.bytesWritten = 0
        XCTAssertEqual(store.applyDeltas([failed])[0].indicators[0].rawDelta, nil)
        store.record([failed])
        XCTAssertEqual(store.samples(driveID: valid.id).count, 1)
        XCTAssertEqual(store.samples(driveID: valid.id).first?.ssdLife, 92)
        XCTAssertEqual(store.indicatorSamples(driveID: valid.id, indicatorID: 5).count, 1)

        let resumed = makeDrive(id: "SERIAL1", checkedAt: start.addingTimeInterval(2 * 86400), indicators: [indicator(raw: 103, current: 90)])
        XCTAssertEqual(store.applyDeltas([resumed])[0].indicators[0].rawDelta, 3)
        store.record([resumed])
        XCTAssertEqual(store.samples(driveID: valid.id).count, 2)
    }

    func testUnavailableTransportDoesNotRecordDefaultZeroHealth() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let unavailable = DriveSnapshot(id: "NO-SMART", bsdName: "disk2", checkedAt: Date())
        store.record([unavailable])
        XCTAssertTrue(store.samples(driveID: unavailable.id).isEmpty)
    }

    func testIndicatorHistoryRecordsOnePointPerSample() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let start = Date()
        store.record([makeDrive(id: "SERIAL1", checkedAt: start, indicators: [indicator(raw: 100, current: 92)])])
        store.record([makeDrive(id: "SERIAL1", checkedAt: start.addingTimeInterval(26 * 3600), indicators: [indicator(raw: 104, current: 92)])])
        // A quick re-check within the 10 minute sample gap must not add another point.
        store.record([makeDrive(id: "SERIAL1", checkedAt: start.addingTimeInterval(26 * 3600 + 120), indicators: [indicator(raw: 104, current: 92)])])

        let samples = store.indicatorSamples(driveID: "SERIAL1", indicatorID: 5)
        XCTAssertEqual(samples.map(\.raw), [100.0, 104.0])
        XCTAssertNil(store.indicatorSamples(driveID: "OTHER", indicatorID: 5).first)
    }

    func testIndicatorTrendOverWindow() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let start = Date()
        store.record([makeDrive(id: "SERIAL1", checkedAt: start, indicators: [indicator(raw: 100, current: 92)])])
        store.record([makeDrive(id: "SERIAL1", checkedAt: start.addingTimeInterval(26 * 3600), indicators: [indicator(raw: 104, current: 92)])])

        let trend = store.indicatorTrend(driveID: "SERIAL1", indicatorID: 5, days: 30)
        XCTAssertEqual(trend?.change, 4)
        XCTAssertEqual(trend?.sampleCount, 2)
        XCTAssertEqual(trend!.spanDays, 26.0 / 24, accuracy: 0.01)

        // One saved check is not a trend.
        let (single, singleURL) = makeStore()
        defer { cleanUp(singleURL) }
        single.record([makeDrive(id: "SERIAL1", checkedAt: start, indicators: [indicator(raw: 100, current: 92)])])
        XCTAssertNil(single.indicatorTrend(driveID: "SERIAL1", indicatorID: 5, days: 30))
    }

    func testIndicatorTrendFallsBackToCurrentValue() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let start = Date()
        store.record([makeDrive(id: "SERIAL1", checkedAt: start, indicators: [indicator(raw: nil, current: 100)])])
        store.record([makeDrive(id: "SERIAL1", checkedAt: start.addingTimeInterval(2 * 86400), indicators: [indicator(raw: nil, current: 96)])])

        let trend = store.indicatorTrend(driveID: "SERIAL1", indicatorID: 5, days: 30)
        XCTAssertEqual(trend?.change, -4)
    }

    func testLifeProjectionForDecliningSSD() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let start = Date()
        let lives: [Double] = [100, 97, 94, 91, 88, 85, 82]
        for (index, life) in lives.enumerated() {
            store.record([makeDrive(id: "SSD1", checkedAt: start.addingTimeInterval(Double(index) * 10 * 86400), ssdLife: life)])
        }

        let note = store.lifeProjectionDescription(driveID: "SSD1", latestLife: 82)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("20% remains") == true)

        // A steady history gives no projection.
        let (steady, steadyURL) = makeStore()
        defer { cleanUp(steadyURL) }
        for index in 0..<6 {
            steady.record([makeDrive(id: "SSD2", checkedAt: start.addingTimeInterval(Double(index) * 10 * 86400), ssdLife: 90)])
        }
        XCTAssertNil(steady.lifeProjectionDescription(driveID: "SSD2", latestLife: 90))
    }

    func testLifeProjectionBelowTwentyPercent() {
        let (store, url) = makeStore()
        defer { cleanUp(url) }
        let start = Date()
        let lives: [Double] = [18, 17, 16, 15, 14, 13]
        for (index, life) in lives.enumerated() {
            store.record([makeDrive(id: "SSD1", checkedAt: start.addingTimeInterval(Double(index) * 10 * 86400), ssdLife: life)])
        }
        XCTAssertEqual(
            store.lifeProjectionDescription(driveID: "SSD1", latestLife: 13),
            "SSD life is already below 20%."
        )
    }
}
