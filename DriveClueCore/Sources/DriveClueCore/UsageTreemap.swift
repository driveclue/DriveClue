import CoreGraphics
import Foundation

/// Lays out size-weighted items as readable rectangles within the map's actual bounds.
/// Items are expected in descending size order, as in the Storage browser.
public enum UsageTreemap {
    private struct Entry {
        let index: Int
        let area: CGFloat
    }

    public static func layout(weights: [UInt64], in bounds: CGRect) -> [CGRect] {
        var rectangles = [CGRect](repeating: .zero, count: weights.count)
        guard bounds.width > 0, bounds.height > 0 else { return rectangles }

        let total = weights.reduce(0.0) { $0 + Double($1) }
        guard total > 0 else { return rectangles }
        let scale = bounds.width * bounds.height / CGFloat(total)
        let entries = weights.enumerated().compactMap { index, weight -> Entry? in
            weight > 0 ? Entry(index: index, area: CGFloat(weight) * scale) : nil
        }

        var remaining = bounds
        var row: [Entry] = []
        var rowArea: CGFloat = 0
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            let side = min(remaining.width, remaining.height)
            let candidate = row + [entry]
            if row.isEmpty || worstRatio(candidate, side: side) <= worstRatio(row, side: side) {
                row.append(entry)
                rowArea += entry.area
                index += 1
            } else {
                remaining = place(row, area: rowArea, in: remaining, output: &rectangles)
                row.removeAll(keepingCapacity: true)
                rowArea = 0
            }
        }
        if !row.isEmpty {
            _ = place(row, area: rowArea, in: remaining, output: &rectangles)
        }
        return rectangles
    }

    private static func worstRatio(_ row: [Entry], side: CGFloat) -> CGFloat {
        let areas = row.map(\.area)
        let sum = areas.reduce(0, +)
        guard side > 0, sum > 0, let minimum = areas.min(), minimum > 0,
              let maximum = areas.max() else { return .infinity }
        let sumSquared = sum * sum
        let sideSquared = side * side
        return max(sideSquared * maximum / sumSquared, sumSquared / (sideSquared * minimum))
    }

    private static func place(
        _ row: [Entry],
        area: CGFloat,
        in bounds: CGRect,
        output: inout [CGRect]
    ) -> CGRect {
        guard !row.isEmpty, bounds.width > 0, bounds.height > 0 else { return bounds }
        if bounds.width >= bounds.height {
            let width = min(area / bounds.height, bounds.width)
            var y = bounds.minY
            for (offset, entry) in row.enumerated() {
                let height = offset == row.count - 1
                    ? max(bounds.maxY - y, 0)
                    : min(entry.area / max(width, .leastNonzeroMagnitude), bounds.maxY - y)
                output[entry.index] = CGRect(x: bounds.minX, y: y, width: width, height: height)
                y += height
            }
            return CGRect(x: bounds.minX + width, y: bounds.minY,
                          width: max(bounds.width - width, 0), height: bounds.height)
        }

        let height = min(area / bounds.width, bounds.height)
        var x = bounds.minX
        for (offset, entry) in row.enumerated() {
            let width = offset == row.count - 1
                ? max(bounds.maxX - x, 0)
                : min(entry.area / max(height, .leastNonzeroMagnitude), bounds.maxX - x)
            output[entry.index] = CGRect(x: x, y: bounds.minY, width: width, height: height)
            x += width
        }
        return CGRect(x: bounds.minX, y: bounds.minY + height,
                      width: bounds.width, height: max(bounds.height - height, 0))
    }
}
