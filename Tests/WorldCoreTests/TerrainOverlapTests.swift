import XCTest
@testable import WorldCore

final class TerrainOverlapTests: XCTestCase {
  func testIndexMatchesBruteForceAcrossNegativeCoordinatesAndAllTileSizes() {
    var tiles = Set<TerrainTile>()
    for size in [1, 2, 4, 8, 16, 32] {
      for x in -2...2 { for z in -2...2 {
        tiles.insert(.init(x: x * size, z: z * size, size: size))
        if size == 1 { tiles.insert(.init(x: x, z: z, fullDetail: true)) }
      } }
    }
    let index = TerrainOverlapIndex(tiles)
    for tile in tiles.union([.init(x: -96, z: 64, size: 32), .init(x: 0, z: 96, size: 32)]) {
      let expected = tiles.filter { $0.overlaps(tile) }
      XCTAssertEqual(Set(index.overlapping(tile)), expected)
      XCTAssertEqual(index.containsOverlap(with: tile), !expected.isEmpty)
    }
  }
  func testCoverageExactlyMatchesPreviousAlgorithmDuringFarHorizonTransitions() {
    for radius in [4, 48, 128] { for detail in [6, 10, 16] {
      let old = TerrainStreamingPlan(center: .init(-14, -10), radius: radius, detailRadius: detail).tiles
      for shift in [0, 4, 12, 100] {
        let desired = TerrainStreamingPlan(center: .init(-14 + shift, -10 + shift / 2), radius: radius,
          detailRadius: detail, lookAhead: .init(-8 + shift, -8 + shift / 2)).tiles
        for fraction in [0, 1, 3] {
          let ordered = desired.sorted { ($0.x, $0.z, $0.size) < ($1.x, $1.z, $1.size) }
          let available = old.union(ordered.enumerated().filter { $0.offset % 3 < fraction }.map(\.element))
          let retired = Set(available.filter { tile in
            !desired.contains(tile) && desired.filter { $0.overlaps(tile) }.allSatisfy { available.contains($0) }
          })
          let remaining = available.subtracting(retired), blockers = remaining.subtracting(desired)
          let visible = Set(remaining.filter { tile in !desired.contains(tile) || !blockers.contains { $0.overlaps(tile) } })
          let actual = TerrainCoverage(desired: desired, available: available)
          XCTAssertEqual(actual.retired, retired)
          XCTAssertEqual(actual.visible, visible)
        }
      }
    } }
  }
}
