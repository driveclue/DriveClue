import CoreGraphics
import XCTest
@testable import DriveClueCore

final class UsageTreemapTests: XCTestCase {
    func testTilesCoverBoundsAndPreserveRelativeArea() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 240)
        let tiles = UsageTreemap.layout(weights: [50, 25, 15, 10], in: bounds)
        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.01)
        for (tile, weight) in zip(tiles, [50.0, 25.0, 15.0, 10.0]) {
            XCTAssertTrue(bounds.contains(tile))
            XCTAssertEqual(tile.width * tile.height / (bounds.width * bounds.height), weight / 100, accuracy: 0.001)
        }
        for left in tiles.indices {
            for right in tiles.indices where left < right {
                let intersection = tiles[left].intersection(tiles[right])
                XCTAssertLessThanOrEqual(intersection.width * intersection.height, 0.01)
            }
        }
    }

    func testZeroWeightHasNoTile() {
        let tiles = UsageTreemap.layout(weights: [2, 0, 1], in: CGRect(x: 0, y: 0, width: 300, height: 100))
        XCTAssertEqual(tiles[1], .zero)
        XCTAssertEqual(tiles[0].width * tiles[0].height, 20_000, accuracy: 0.01)
        XCTAssertEqual(tiles[2].width * tiles[2].height, 10_000, accuracy: 0.01)
    }
}
