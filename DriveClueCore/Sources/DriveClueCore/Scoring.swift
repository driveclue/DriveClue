import Foundation

public enum DriveScorer {
    public static func score(attribute: RawAttribute, model: String, isSSD: Bool, sectorSize: Int = 512) -> HealthIndicator {
        let info = AttributeCatalog.info(id: attribute.id, model: model)
        let kind: IndicatorKind = attribute.flags & 0x01 != 0 ? .preFail : info.kind
        let mode: UpdateMode = attribute.flags & 0x02 != 0 ? .online : (attribute.flags == 0 ? .unknown : .offline)
        let rating = rating(current: attribute.current, threshold: attribute.threshold)
        var status: IndicatorStatus = .ok
        if attribute.threshold > 0 && attribute.current <= attribute.threshold {
            status = .failed
        } else if info.failingWhenRawPositive && attribute.raw > 0 {
            status = .failing
        } else if let rating, rating < 10 {
            status = .failing
        } else if info.warningWhenRawPositive && attribute.raw > 0 {
            status = .warning
        } else if let rating, rating < 30 {
            status = .warning
        }
        if attribute.id == 194 || attribute.id == 190 {
            let temp = ATAParser.temperatureRange(attribute: attribute).current ?? 0
            let limit = isSSD ? 70 : 55
            if temp >= limit + 15 { status = worse(status, .failing) }
            else if temp >= limit { status = worse(status, .warning) }
        }
        return HealthIndicator(
            id: attribute.id,
            name: info.name,
            kind: kind,
            updateMode: mode,
            raw: attribute.raw,
            rawDisplay: rawText(attribute: attribute, style: info.rawStyle, sectorSize: sectorSize),
            rawIsApproximate: info.rawStyle == .hex,
            current: attribute.current,
            worst: attribute.worst,
            threshold: attribute.threshold > 0 ? attribute.threshold : nil,
            rating: rating,
            status: status,
            explanation: info.explanation,
            isImportant: info.isImportant,
            affectsPerformance: info.affectsPerformance,
            countsTowardHealth: info.countsTowardHealth
        )
    }

    public static func summarize(_ indicators: [HealthIndicator], isSSD: Bool) -> (health: Double, healthBand: HealthBand, performance: Double?, performanceBand: HealthBand?, ssdLife: Double?, ssdLifeBand: HealthBand?, status: IndicatorStatus, issues: Int) {
        let healthPool = indicators.filter(\.countsTowardHealth).compactMap(\.rating)
        let health = healthPool.min() ?? 100
        let performancePool = indicators.filter(\.affectsPerformance).compactMap(\.rating)
        let performance = performancePool.isEmpty ? nil : performancePool.min()
        let life = ssdLife(indicators, isSSD: isSSD)
        let worst = indicators.map(\.status).max() ?? .ok
        let issues = indicators.filter { $0.status != .ok }.count
        let status: IndicatorStatus
        switch worst {
        case .failed: status = .failed
        case .failing: status = .failing
        case .warning, .ok: status = issues > 0 && worst == .warning ? .warning : .ok
        }
        return (
            health,
            HealthBand.band(for: health),
            performance,
            performance.map(HealthBand.band(for:)),
            life,
            life.map(HealthBand.band(for:)),
            status,
            issues
        )
    }

    public static func ssdLife(_ indicators: [HealthIndicator], isSSD: Bool) -> Double? {
        guard isSSD else { return nil }
        if let percent = indicators.first(where: { $0.id == 5 && $0.name == "Percentage Used" })?.rating {
            return percent
        }
        for id in [231, 233, 202, 177] {
            if let value = indicators.first(where: { $0.id == id })?.current {
                return Double(min(100, max(0, value)))
            }
        }
        return nil
    }

    public static func rating(current: Int, threshold: Int) -> Double? {
        if current <= 0 && threshold <= 0 { return nil }
        if threshold > 0 && current <= threshold { return 0 }
        let ideal: Double
        if current > 200 { ideal = 253 }
        else if current > 100 { ideal = 200 }
        else { ideal = 100 }
        let floor = Double(max(threshold, 0))
        let span = max(ideal - floor, 1)
        return min(100, max(0, (Double(current) - floor) / span * 100))
    }

    public static func rawText(attribute: RawAttribute, style: AttributeInfo.RawStyle, sectorSize: Int) -> String {
        switch style {
        case .hex:
            return String(format: "0x%X", attribute.raw)
        case .temperature:
            let current = Int(attribute.raw & 0xFF)
            return "\(current) °C"
        case .hours:
            return ByteFormat.durationHours(Int(attribute.raw & 0xFFFFFFFF))
        case .lba:
            let bytes = attribute.raw * UInt64(max(sectorSize, 512))
            return "\(ByteFormat.decimal(attribute.raw)) (\(ByteFormat.bytes(bytes)))"
        case .decimal:
            return ByteFormat.decimal(attribute.raw)
        }
    }

    private static func worse(_ lhs: IndicatorStatus, _ rhs: IndicatorStatus) -> IndicatorStatus {
        max(lhs, rhs)
    }
}
