import Foundation
import XCTest
@testable import WorldCore

final class TerrainCoverageDiagnosticsTests: XCTestCase, @unchecked Sendable {
  private func observation(world: UUID, target: Set<TerrainTile>, visible: Set<TerrainTile>, time: Double,
    center: ChunkCoordinate = .init(-64, -64), radius: Int = 16,
    direction: SIMD3<Float> = [1, 0, 0]) -> TerrainCoverageObservation {
    .init(world: world, center: center, radius: radius, detailRadius: 6,
      target: target, visible: visible, direction: direction, time: time)
  }

  func testDistanceBandsAndDirectionExposeUncoveredForwardTerrain() {
    let world = UUID(), center = ChunkCoordinate(-64, -64)
    let targets = TerrainStreamingPlan(center: center, radius: 16, detailRadius: 6).tiles
    let west: Set<TerrainTile> = [.init(x: -96, z: -96, size: 32), .init(x: -96, z: -64, size: 32)]
    var history = TerrainCoverageHistory()
    let eastLook = history.observe(observation(world: world, target: targets, visible: west, time: 1))
    XCTAssertEqual(eastLook.bands.map(\.maximumMetres), [48, 64, 128])
    let area = TerrainCoverageMetrics(center: center, radius: 16, target: targets, visible: west)
    XCTAssertEqual(eastLook.uncoveredChunks, area.requestedChunks - area.visibleChunks)
    XCTAssertEqual(eastLook.bands.reduce(0) { $0 + $1.requestedChunks }, area.requestedChunks)
    XCTAssertLessThan(eastLook.forwardSectorPercent!, 1)
    let westLook = history.observe(observation(world: world, target: targets, visible: west, time: 1.25, direction: [-1, 0, 0]))
    XCTAssertGreaterThan(westLook.forwardSectorPercent!, 99)
    let sky = history.observe(observation(world: world, target: targets, visible: west, time: 1.5, direction: [0, 1, 0]))
    XCTAssertNil(sky.forwardSectorPercent)
  }

  func testVisibleFallbackRecordsCoverageBeforeRequestedDetailAndResetsOnTravel() {
    let world = UUID(), tile = TerrainTile(x: -64, z: -64, fullDetail: true)
    let parent = TerrainTile(x: -64, z: -64, size: 32)
    var history = TerrainCoverageHistory()
    let missing = history.observe(observation(world: world, target: [tile], visible: [], time: 10))
    XCTAssertEqual(missing.pendingCoverage, 1); XCTAssertEqual(missing.pendingDetail, 1)
    let fallback = history.observe(observation(world: world, target: [tile], visible: [parent], time: 10.5))
    XCTAssertEqual(fallback.pendingCoverage, 0); XCTAssertEqual(fallback.pendingDetail, 1)
    XCTAssertEqual(fallback.wantedToCoverage.meanMilliseconds, 500)
    XCTAssertEqual(fallback.wantedToDetail.count, 0, "Hidden installed descendants are not visible detail")
    let final = history.observe(observation(world: world, target: [tile], visible: [tile], time: 11.25))
    XCTAssertEqual(final.pendingDetail, 0)
    XCTAssertEqual(final.wantedToDetail.meanMilliseconds, 1_250)
    XCTAssertEqual(final.coverageToDetail.meanMilliseconds, 750)
    let repeated = history.observe(observation(world: world, target: [tile], visible: [tile], time: 15))
    XCTAssertEqual(repeated.wantedToDetail.count, 1)
    let gap = history.observe(observation(world: world, target: [tile], visible: [], time: 16))
    XCTAssertEqual(gap.pendingCoverage, 1); XCTAssertEqual(gap.pendingDetail, 1)
    XCTAssertEqual(gap.coverageLosses, 1); XCTAssertEqual(gap.detailLosses, 1)
    let moved = TerrainTile(x: 10, z: 10, fullDetail: true)
    let movement = history.observe(observation(world: world, target: [moved], visible: [], time: 20))
    XCTAssertEqual(movement.pendingDetail, 1); XCTAssertEqual(movement.oldestDetailMilliseconds, 0)
    let travelled = history.observe(observation(world: UUID(), target: [tile], visible: [], time: 30))
    XCTAssertEqual(travelled.wantedToCoverage.count, 0); XCTAssertEqual(travelled.oldestCoverageMilliseconds, 0)
  }

  func testCompleteCoverageIncludesAllBandsAndFirst95Timing() {
    let world = UUID(), center = ChunkCoordinate(-64, -64)
    let target = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
    var history = TerrainCoverageHistory()
    _ = history.observe(observation(world: world, target: target, visible: [], time: 1, radius: 128))
    let ready = history.observe(observation(world: world, target: target, visible: target, time: 3.5, radius: 128))
    XCTAssertEqual(ready.uncoveredChunks, 0); XCTAssertEqual(ready.forwardSectorPercent, 100)
    XCTAssertTrue(ready.bands.allSatisfy { $0.coveredPercent == 100 })
    XCTAssertEqual(ready.pendingDetail, 0); XCTAssertEqual(ready.first95PercentMilliseconds, 2_500)
  }

  func testLatestSampleReplacesBacklogAndRunsOffMainThread() async throws {
    let diagnostics = TerrainCoverageDiagnostics(), oldWorld = UUID(), newWorld = UUID()
    let tile = TerrainTile(x: -64, z: -64, size: 32)
    for n in 0..<500 {
      diagnostics.submit(observation(world: oldWorld, target: [tile], visible: [], time: Double(n)))
    }
    diagnostics.submit(observation(world: newWorld, target: [tile], visible: [tile], time: 1_000))
    for _ in 0..<200 {
      if diagnostics.snapshot.sampledAt == 1_000 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let final = diagnostics.snapshot
    XCTAssertEqual(final.sampledAt, 1_000); XCTAssertEqual(final.pendingDetail, 0)
    XCTAssertEqual(final.wantedToDetail.count, 1); XCTAssertEqual(final.mainThreadViolations, 0)
    XCTAssertEqual(final.oldestDetailMilliseconds, 0)
  }
}
