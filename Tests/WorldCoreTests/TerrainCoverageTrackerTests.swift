import XCTest
@testable import WorldCore

final class TerrainCoverageTrackerTests: XCTestCase {
  /// Replay the scene's install/retire lifecycle against the original, stateless
  /// whole-world resolver. Compare deltas as well as the resulting visible set.
  private struct Replay {
    var tracker = TerrainCoverageTracker()
    var desired: Set<TerrainTile> = [], available: Set<TerrainTile> = [], visible: Set<TerrainTile> = []

    @discardableResult mutating func step(
      target: Set<TerrainTile>? = nil, installed: Set<TerrainTile> = [],
      file: StaticString = #filePath, line: UInt = #line
    ) -> TerrainCoverageTracker.Changes {
      if let target { desired = target; tracker.setDesired(target) }
      for tile in installed { tracker.insert(tile) }
      available.formUnion(installed)
      let expected = TerrainCoverage(desired: desired, available: available)
      let change = tracker.resolve()
      XCTAssertEqual(change.retired, expected.retired, file: file, line: line)
      XCTAssertEqual(change.becameHidden, visible.subtracting(expected.visible), file: file, line: line)
      XCTAssertEqual(change.becameVisible, expected.visible.subtracting(visible), file: file, line: line)
      available.subtract(change.retired)
      visible.subtract(change.becameHidden); visible.formUnion(change.becameVisible)
      XCTAssertEqual(visible, expected.visible, file: file, line: line)
      let metrics = tracker.metrics
      XCTAssertEqual(metrics.desiredTiles, desired.count, file: file, line: line)
      XCTAssertEqual(metrics.availableTiles, available.count, file: file, line: line)
      XCTAssertEqual(metrics.visibleTiles, visible.count, file: file, line: line)
      XCTAssertEqual(metrics.dirtyRegions, 0, file: file, line: line)
      return change
    }
  }

  func testPartialSiblingArrivalsKeepParentUntilLastChildAndReleaseRegion() {
    var replay = Replay()
    let parent = TerrainTile(x: -32, z: 32, size: 32)
    let children = [TerrainTile(x: -32, z: 32, size: 16), .init(x: -16, z: 32, size: 16),
      .init(x: -32, z: 48, size: 16), .init(x: -16, z: 48, size: 16)]
    replay.step(target: [parent], installed: [parent])
    replay.step(target: Set(children))
    for child in children.dropLast() {
      replay.step(installed: [child])
      XCTAssertEqual(replay.visible, [parent])
      replay.step() // A failed/delayed install changes no ownership.
    }
    let last = replay.step(installed: [children.last!])
    XCTAssertEqual(last.retired, [parent]); XCTAssertEqual(last.becameHidden, [parent])
    XCTAssertEqual(replay.visible, Set(children))
    replay.step(target: [])
    XCTAssertEqual(replay.tracker.metrics.regions, 0)
    XCTAssertTrue(replay.available.isEmpty); XCTAssertTrue(replay.visible.isEmpty)
  }

  func testSameCellFullDetailAndSurfaceExchangesAndDuplicateContentEdits() {
    let full = TerrainTile(x: -1, z: -33, fullDetail: true)
    let surface = TerrainTile(x: -1, z: -33)
    var replay = Replay()
    replay.step(target: [surface], installed: [surface])
    replay.step(target: [full])
    XCTAssertEqual(replay.visible, [surface])
    replay.step(installed: [full])
    XCTAssertEqual(replay.visible, [full])
    let examined = replay.tracker.metrics.availableTilesExamined
    replay.step(target: [full], installed: [full])
    replay.step()
    XCTAssertEqual(replay.tracker.metrics.availableTilesExamined, examined)
    XCTAssertEqual(replay.tracker.metrics.unchangedResolutions, 2)
    replay.step(target: [surface])
    XCTAssertEqual(replay.visible, [full])
    replay.step(installed: [surface])
    XCTAssertEqual(replay.visible, [surface])
  }

  func testInterruptedNestedReplacementCannotExposeHiddenObsoleteDescendant() {
    var replay = Replay()
    let parent = TerrainTile(x: -32, z: -64, size: 8)
    let hidden = TerrainTile(x: -32, z: -64, size: 4)
    let intermediate: Set<TerrainTile> = [hidden, .init(x: -28, z: -64, size: 4),
      .init(x: -32, z: -60, size: 4), .init(x: -28, z: -60, size: 4)]
    replay.step(target: [parent], installed: [parent])
    replay.step(target: intermediate, installed: [hidden])
    XCTAssertEqual(replay.visible, [parent])
    let leaves = Set((0..<8).flatMap { z in (0..<8).map { x in
      TerrainTile(x: -32 + x, z: -64 + z, fullDetail: true)
    } })
    let interrupted = replay.step(target: leaves)
    XCTAssertEqual(interrupted.retired, [hidden])
    XCTAssertEqual(replay.visible, [parent])
    // A stale obsolete result is conservatively retired even if a caller allows
    // it to reach the tracker; the renderer normally rejects it before install.
    replay.step(installed: [hidden])
    XCTAssertEqual(replay.visible, [parent])
    replay.step(installed: leaves)
    XCTAssertEqual(replay.visible, leaves)
  }

  func testChangedRegionDoesNotRevisitUnrelatedHorizonOrDetail() {
    var replay = Replay()
    let roots = Set((-8..<8).flatMap { z in (-8..<8).map { x in
      TerrainTile(x: x * 32, z: z * 32, size: 32)
    } })
    replay.step(target: roots, installed: roots)
    let root = TerrainTile(x: 0, z: -32, size: 32)
    let children: Set<TerrainTile> = [.init(x: 0, z: -32, size: 16), .init(x: 16, z: -32, size: 16),
      .init(x: 0, z: -16, size: 16), .init(x: 16, z: -16, size: 16)]
    let before = replay.tracker.metrics
    replay.step(target: roots.subtracting([root]).union(children), installed: children)
    let after = replay.tracker.metrics
    XCTAssertEqual(after.regionsResolved - before.regionsResolved, 1)
    XCTAssertEqual(after.availableTilesExamined - before.availableTilesExamined, 5)
    XCTAssertEqual(after.desiredTilesExamined - before.desiredTilesExamined, 4)
    XCTAssertEqual(after.regions, roots.count)
    XCTAssertEqual(replay.visible, roots.subtracting([root]).union(children))
  }

  func testProgressiveMovementReversalTeleportAndDrawDistanceChangesMatchFullScan() {
    var replay = Replay(), planner = ProgressiveTerrainPlanner()
    let visits: [(ChunkCoordinate, Int, Int, Int)] = [
      (.init(19, 51), 128, 16, 2_000), (.init(23, 51), 128, 16, 31),
      (.init(19, 51), 128, 16, 2_000), (.init(-33, -65), 128, 16, 47),
      (.init(-31, -63), 48, 10, 2_000), (.init(32, 32), 256, 24, 2_000)
    ]
    for (center, radius, detail, limit) in visits {
      let target = TerrainStreamingPlan(center: center, radius: radius, detailRadius: detail).tiles
      for step in 0..<limit {
        let frontier = planner.plan(target: target, visible: replay.visible, center: center).tiles
        replay.step(target: frontier)
        let pending = frontier.subtracting(replay.available).sorted {
          ($0.size, $0.x, $0.z, $0.fullDetail ? 1 : 0) < ($1.size, $1.x, $1.z, $1.fullDetail ? 1 : 0)
        }
        // Reverse ready order periodically; leave incomplete groups across moves.
        replay.step(installed: Set((step % 2 == 0 ? pending : pending.reversed()).prefix(1 + step % 8)))
        if step % 17 == 0 {
          let index = TerrainOverlapIndex(replay.visible)
          for tile in replay.visible { XCTAssertEqual(index.overlapping(tile).count, 1) }
        }
        if replay.visible == target { break }
      }
      if limit == 2_000 { XCTAssertEqual(replay.visible, target) }
    }
    replay.step(target: [])
    XCTAssertEqual(replay.tracker.metrics.regions, 0)
  }

  func testRandomizedMixedLevelsAcrossSignedRegionBoundariesMatchFullScan() {
    var replay = Replay(), state: UInt64 = 0xFEED_CAFE
    func next(_ upper: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      return Int((state >> 32) % UInt64(upper))
    }
    var universe: [TerrainTile] = []
    for _ in 0..<500 {
      let size = 1 << next(6), x = next(256) - 128, z = next(256) - 128
      universe.append(.init(x: floorDivide(x, by: size) * size, z: floorDivide(z, by: size) * size,
        size: size, fullDetail: size == 1 && next(2) == 0))
    }
    var desired: Set<TerrainTile> = []
    for _ in 0..<4_000 {
      for _ in 0..<next(5) {
        let tile = universe[next(universe.count)]
        if next(2) == 0 { desired.insert(tile) } else { desired.remove(tile) }
      }
      var installed: Set<TerrainTile> = []
      for _ in 0..<next(9) { installed.insert(universe[next(universe.count)]) }
      replay.step(target: desired, installed: installed)
    }
    replay.step(target: [])
    XCTAssertEqual(replay.tracker.metrics.regions, 0)
  }

  func testResetDropsDirtyStateAndAllowsWorldReuse() {
    var tracker = TerrainCoverageTracker()
    let old = TerrainTile(x: -32, z: 32, size: 32)
    tracker.setDesired([old]); tracker.insert(old)
    XCTAssertEqual(tracker.metrics.dirtyRegions, 1)
    tracker.reset()
    let metrics = tracker.metrics
    XCTAssertEqual(metrics.regions, 0); XCTAssertEqual(metrics.dirtyRegions, 0)
    XCTAssertEqual(metrics.resolutions, 0); XCTAssertEqual(metrics.desiredTiles, 0)
    XCTAssertEqual(metrics.availableTiles, 0); XCTAssertEqual(metrics.visibleTiles, 0)
    XCTAssertEqual(metrics.regionsResolved, 0); XCTAssertEqual(metrics.unchangedResolutions, 0)
    XCTAssertEqual(metrics.desiredTilesExamined, 0); XCTAssertEqual(metrics.availableTilesExamined, 0)
    let empty = tracker.resolve()
    XCTAssertTrue(empty.retired.isEmpty); XCTAssertTrue(empty.becameVisible.isEmpty)
    tracker.setDesired([old]); tracker.insert(old)
    XCTAssertEqual(tracker.resolve().becameVisible, [old])
  }
}
