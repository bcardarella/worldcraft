import XCTest
@testable import WorldCore

final class ProgressiveTerrainTests: XCTestCase {
  func testColdFrontierCoversFullRadiusWithoutHundredsOfVoxelJobs() {
    let center = ChunkCoordinate(19, 51)
    let target = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
    let first = ProgressiveTerrainPlan(target: target, visible: [], center: center).tiles
    XCTAssertLessThan(first.count, 160)
    XCTAssertLessThan(first.filter(\.fullDetail).count, 40)
    XCTAssertTrue(first.contains(.init(x: center.x, z: center.z, fullDetail: true)))
    let metrics = TerrainCoverageMetrics(center: center, radius: 128, target: target, visible: first)
    XCTAssertEqual(metrics.coveredPercent, 100, accuracy: 0.0001)
    XCTAssertEqual(metrics.minimumQuadrantPercent, 100, accuracy: 0.0001)
    XCTAssertLessThan(metrics.requestedDetailPercent, 10)
    assertDisjoint(first)
  }

  func testRefinementConvergesWithoutCoverageHolesOrHugeReplacementGroups() {
    for center in [ChunkCoordinate(19, 51), .init(-33, -65), .init(0, 0)] {
      let target = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
      var visible: Set<TerrainTile> = []
      for _ in 0..<12 {
        let next = ProgressiveTerrainPlan(target: target, visible: visible, center: center).tiles
        for parent in visible.subtracting(next) {
          XCTAssertLessThanOrEqual(next.filter { $0.overlaps(parent) }.count, 16)
        }
        // A partially prepared replacement cannot remove fallback coverage.
        let partial = next.subtracting(visible).sorted { ($0.x, $0.z, $0.size) < ($1.x, $1.z, $1.size) }.prefix(5)
        let during = TerrainCoverage(desired: next, available: visible.union(partial))
        assertDisjoint(during.visible)
        if !visible.isEmpty {
          XCTAssertEqual(TerrainCoverageMetrics(center: center, radius: 128, target: target,
            visible: during.visible).coveredPercent, 100, accuracy: 0.0001)
        }
        let complete = TerrainCoverage(desired: next, available: visible.union(next))
        visible = complete.visible
        assertDisjoint(visible)
        if visible == target { break }
      }
      XCTAssertEqual(visible, target)
    }
  }

  func testMovementPreservesExistingNearDetailAndNegativeCoordinateCoverage() {
    let oldCenter = ChunkCoordinate(-17, -31), center = ChunkCoordinate(-13, -27)
    let old = TerrainStreamingPlan(center: oldCenter, radius: 48, detailRadius: 16).tiles
    let target = TerrainStreamingPlan(center: center, radius: 48, detailRadius: 16).tiles
    let next = ProgressiveTerrainPlan(target: target, visible: old, center: center).tiles
    XCTAssertTrue(old.intersection(target).filter(\.fullDetail).isSubset(of: next))
    let during = TerrainCoverage(desired: next, available: old)
    assertDisjoint(during.visible)
    let shared = old.intersection(target)
    XCTAssertTrue(shared.isSubset(of: during.visible))
  }

  func testMetricsDetectMissingDirectionAndDoNotCountCoarseAsDetail() {
    let center = ChunkCoordinate(0, 0)
    let target = TerrainStreamingPlan(center: center, radius: 32, detailRadius: 10).tiles
    let visible = Set(target.filter { $0.x >= 0 })
    let sample = TerrainCoverageMetrics(center: center, radius: 32, target: target, visible: visible)
    XCTAssertLessThan(sample.coveredPercent, 55)
    XCTAssertEqual(sample.minimumQuadrantPercent, 0)
    XCTAssertLessThan(sample.requestedDetailPercent, 100)
  }

  func testMeasuredPublicationBudgetDoesNotThrottleCheapWorkAt45Hz() {
    var budget = StreamingBudget()
    for frame in 0..<100 {
      let now = Double(frame) / 45
      XCTAssertTrue(budget.beginFrame(interval: 1 / 45, time: now, urgent: false))
      budget.recordTile(seconds: 0.0006)
      XCTAssertTrue(budget.allowsNextTile(elapsed: 0.0006, published: 1, bytes: 100_000, urgent: false))
      XCTAssertFalse(budget.allowsNextTile(elapsed: 0.0022, published: 2, bytes: 200_000, urgent: false))
      XCTAssertFalse(budget.allowsNextTile(elapsed: 0.0006, published: 1,
        bytes: StreamingBudget.maximumFrameBytes, urgent: false))
      budget.published(cpuTime: 0.002, time: now)
    }
    XCTAssertTrue(budget.allowsNextTile(elapsed: 1, published: 0, bytes: 0, urgent: false))
  }

  func testUncoveredNearDetailCannotConsumeTheHorizonServiceShare() {
    let near = TerrainTile(x: 6, z: 0, fullDetail: true)
    let coarse = TerrainTile(x: 64, z: 0, size: 32)
    let small = TerrainTile(x: 40, z: 0, size: 1)
    let ordering = TerrainWorkPriority.streaming(desired: [near, coarse, small], available: [],
      center: .init(0, 0), lookAhead: .init(0, 0))
    XCTAssertEqual(ordering.services[near], .detail)
    XCTAssertEqual(ordering.services[coarse], .coverage)
    XCTAssertLessThan(ordering.ranks[coarse]!, ordering.ranks[small]!)
  }

  func testReusedTargetMatchesOriginalPlanningThroughoutPartialPublication() {
    for center in [ChunkCoordinate(19, 51), .init(-33, -65), .init(0, 0)] {
      let target = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
      var planner = ProgressiveTerrainPlanner(maximumReplacementTiles: 8)
      var visible: Set<TerrainTile> = [], available: Set<TerrainTile> = []
      var step = 0
      while visible != target && step < 600 {
        let expected = originalPlan(target: target, visible: visible, center: center)
        let next = planner.plan(target: target, visible: visible, center: center).tiles
        XCTAssertEqual(next, expected)
        let pending = next.subtracting(available).sorted { ($0.x, $0.z, $0.size) < ($1.x, $1.z, $1.size) }
        // Individual/partial arrivals exercise ownership changes instead of
        // swapping every level in one operation. Old parents must survive.
        available.formUnion(pending.prefix(1 + step % 7))
        let coverage = TerrainCoverage(desired: next, available: available)
        available.subtract(coverage.retired); visible = coverage.visible
        assertDisjoint(visible)
        step += 1
      }
      XCTAssertEqual(visible, target)
      XCTAssertEqual(planner.metrics.builds, 1)
      XCTAssertEqual(planner.metrics.reuses, step - 1)
      XCTAssertEqual(planner.metrics.targetTiles, target.count)
    }
  }

  func testTargetReuseDoesNotReuseVisibilityOrViewerPosition() {
    let center = ChunkCoordinate(-13, -27)
    let target = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
    var planner = ProgressiveTerrainPlanner(maximumReplacementTiles: 8)
    let first = planner.plan(target: target, visible: [], center: center).tiles
    for (position, visible) in [(center, first), (.init(-9, -26), Set<TerrainTile>()),
      (.init(-14, -30), target), (center, Set(first.sorted { $0.x < $1.x }.prefix(7)))] {
      let value = planner.plan(target: target, visible: visible, center: position).tiles
      XCTAssertEqual(value, originalPlan(target: target, visible: visible, center: position))
    }
    XCTAssertEqual(planner.metrics.builds, 1); XCTAssertEqual(planner.metrics.reuses, 4)
  }

  func testChangedTargetReplacementResetAndDisabledControl() {
    let center = ChunkCoordinate(19, 51)
    var planner = ProgressiveTerrainPlanner(maximumReplacementTiles: 8)
    var control = ProgressiveTerrainPlanner(enabled: false, maximumReplacementTiles: 8)
    let initial = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
    let moved = TerrainStreamingPlan(center: .init(27, 55), radius: 128, detailRadius: 16).tiles
    let smaller = TerrainStreamingPlan(center: center, radius: 48, detailRadius: 10).tiles
    // Full/surface switches occupy exactly the same footprint but are different
    // target demands. They must not reuse the former ownership hierarchy.
    let surface: Set<TerrainTile> = [.init(x: 0, z: 0)]
    let voxel: Set<TerrainTile> = [.init(x: 0, z: 0, fullDetail: true)]
    for target in [initial, initial, moved, smaller, surface, voxel, []] {
      let value = planner.plan(target: target, visible: [], center: center).tiles
      XCTAssertEqual(value, originalPlan(target: target, visible: [], center: center))
      XCTAssertEqual(value, control.plan(target: target, visible: [], center: center).tiles)
      XCTAssertEqual(planner.metrics.targetTiles, target.count)
      XCTAssertEqual(control.metrics.targetTiles, 0, "Control keeps no previous index")
    }
    XCTAssertEqual(planner.metrics.builds, 6); XCTAssertEqual(planner.metrics.reuses, 1)
    XCTAssertEqual(control.metrics.builds, 7); XCTAssertEqual(control.metrics.reuses, 0)
    planner.reset()
    XCTAssertEqual(planner.metrics.builds, 0); XCTAssertEqual(planner.metrics.reuses, 0)
    XCTAssertEqual(planner.metrics.targetTiles, 0); XCTAssertEqual(planner.metrics.roots, 0)
    XCTAssertEqual(planner.plan(target: initial, visible: [], center: center).tiles,
      originalPlan(target: initial, visible: [], center: center))
    XCTAssertEqual(planner.metrics.builds, 1)
  }

  func testDirectLeavesSkipTemporaryMeshesButWaitForTheLastSibling() {
    let parent = TerrainTile(x: -16, z: 32, size: 4)
    let leaves = Set((0..<4).flatMap { z in (0..<4).map { x in
      TerrainTile(x: parent.x + x, z: parent.z + z, fullDetail: true)
    } })
    let center = ChunkCoordinate(0, 0)
    let next = ProgressiveTerrainPlan(target: leaves, visible: [parent], center: center).tiles
    XCTAssertEqual(next, leaves)
    let old = ProgressiveTerrainPlan(target: leaves, visible: [parent], center: center,
      maximumReplacementTiles: 8).tiles
    XCTAssertEqual(old.count, 4)
    XCTAssertTrue(old.allSatisfy { $0.size == 2 && !$0.fullDetail })

    // Failed or delayed final work cannot expose a hole or duplicate the parent.
    let ordered = leaves.sorted { ($0.x, $0.z) < ($1.x, $1.z) }
    for ready in 0..<ordered.count {
      let available = Set(ordered.prefix(ready)).union([parent])
      let partial = TerrainCoverage(desired: next, available: available)
      XCTAssertEqual(partial.visible, [parent])
      XCTAssertTrue(partial.retired.isEmpty)
    }
    let complete = TerrainCoverage(desired: next, available: leaves.union([parent]))
    XCTAssertEqual(complete.visible, leaves)
    XCTAssertEqual(complete.retired, [parent])
  }

  func testImmediateNeighbourhoodAndInvalidConfigurationKeepBoundedGroups() {
    let parent = TerrainTile(x: 0, z: 0, size: 4)
    let target = Set((0..<4).flatMap { z in (0..<4).map { x in
      TerrainTile(x: x, z: z, fullDetail: true)
    } })
    for center in [ChunkCoordinate(1, 1), .init(-2, 0)] {
      let near = ProgressiveTerrainPlan(target: target, visible: [parent], center: center).tiles
      XCTAssertEqual(near.count, 4)
      XCTAssertTrue(near.allSatisfy { $0.size == 2 })
    }
    for (configuration, expected) in [(Int.min, 4), (8, 8), (16, 16), (Int.max, 16)] {
      var planner = ProgressiveTerrainPlanner(maximumReplacementTiles: configuration)
      let planned = planner.plan(target: target, visible: [parent], center: .init(20, 20)).tiles
      XCTAssertLessThanOrEqual(planned.count, expected)
      XCTAssertEqual(planner.metrics.maximumReplacementTiles, expected)
      XCTAssertEqual(planned, ProgressiveTerrainPlan(target: target, visible: [parent],
        center: .init(20, 20), maximumReplacementTiles: configuration).tiles)
      planner.reset()
      XCTAssertEqual(planner.metrics.maximumReplacementTiles, expected)
    }
  }

  func testPartialDirectGroupsSurviveMovementTargetChangesAndReversal() {
    for limit in [8, 16] {
      var planner = ProgressiveTerrainPlanner(maximumReplacementTiles: limit)
      var available: Set<TerrainTile> = [], visible: Set<TerrainTile> = []
      for center in [ChunkCoordinate(-33, -65), .init(-25, -65), .init(-33, -65)] {
        let target = TerrainStreamingPlan(center: center, radius: 48, detailRadius: 16).tiles
        var steps = 0
        repeat {
          let next = planner.plan(target: target, visible: visible, center: center).tiles
          for parent in visible.subtracting(next) {
            let bound = parent.distanceSquared(to: center) <= 4 ? min(8, limit) : limit
            XCTAssertLessThanOrEqual(next.filter { $0.overlaps(parent) }.count, bound)
          }
          let pending = next.subtracting(available).sorted {
            ($0.size, $0.z, $0.x, $0.fullDetail ? 1 : 0) < ($1.size, $1.z, $1.x, $1.fullDetail ? 1 : 0)
          }
          // Reverse completion order and leave groups incomplete between moves.
          available.formUnion(pending.reversed().prefix(1 + steps % 5))
          let change = TerrainCoverage(desired: next, available: available)
          available.subtract(change.retired); visible = change.visible
          assertDisjoint(visible)
          steps += 1
          if center.x == -25 && steps == 35 { break }
        } while visible != target && steps < 1_000
        if center.x != -25 { XCTAssertEqual(visible, target) }
      }
    }
  }

  func testLargeGroupsOnlyApplyToTheInitialUnchangedDemand() {
    let parent = TerrainTile(x: 32, z: 32, size: 4)
    let leaves = Set((0..<4).flatMap { z in (0..<4).map { x in
      TerrainTile(x: parent.x + x, z: parent.z + z, fullDetail: true)
    } })
    let center = ChunkCoordinate(0, 0)
    for reuse in [false, true] {
      var planner = ProgressiveTerrainPlanner(enabled: reuse)
      XCTAssertEqual(planner.plan(target: leaves, visible: [parent], center: center).tiles, leaves)
      XCTAssertTrue(planner.metrics.initialRefinement)
      XCTAssertEqual(planner.metrics.appliedReplacementTiles, 16)
      var changed = leaves
      changed.insert(.init(x: 128, z: 128, size: 32))
      _ = planner.plan(target: changed, visible: [parent], center: center)
      XCTAssertFalse(planner.metrics.initialRefinement)
      XCTAssertEqual(planner.metrics.appliedReplacementTiles, 8)
      let returned = planner.plan(target: leaves, visible: [parent], center: center).tiles
      XCTAssertEqual(returned.count, 4, "Reversal must not restart large replacement groups")
      let installedHidden = Set(leaves.sorted { ($0.x, $0.z) < ($1.x, $1.z) }.prefix(7))
      let duringChange = TerrainCoverage(desired: returned, available: installedHidden.union([parent]))
      XCTAssertEqual(duringChange.visible, [parent], "An obsolete hidden child is not another fallback")
      XCTAssertEqual(duringChange.retired, installedHidden)
      planner.reset()
      XCTAssertTrue(planner.metrics.initialRefinement)
      XCTAssertEqual(planner.plan(target: leaves, visible: [parent], center: center).tiles, leaves)
      _ = planner.plan(target: leaves, visible: leaves, center: center)
      XCTAssertFalse(planner.metrics.initialRefinement)
      XCTAssertEqual(planner.metrics.appliedReplacementTiles, 8)
    }
  }

  func testAbandonedNestedFallbacksKeepOneCompleteOwner() {
    let outer = TerrainTile(x: -32, z: -32, size: 32)
    let middle = TerrainTile(x: -16, z: -16, size: 16)
    let small = TerrainTile(x: -8, z: -8, size: 8)
    let surface = TerrainTile(x: -1, z: -1)
    let voxel = TerrainTile(x: -1, z: -1, fullDetail: true)
    let obsolete: Set<TerrainTile> = [middle, small, surface, voxel]
    let target: Set<TerrainTile> = [.init(x: -32, z: -32, size: 16),
      .init(x: -16, z: -32, size: 16), .init(x: -32, z: -16, size: 16),
      .init(x: -16, z: -16, size: 8), .init(x: -8, z: -16, size: 8),
      .init(x: -16, z: -8, size: 8), .init(x: -8, z: -8, size: 4),
      .init(x: -4, z: -8, size: 4), .init(x: -8, z: -4, size: 4), .init(x: -4, z: -4, size: 4)]
    let pending = TerrainCoverage(desired: target, available: obsolete.union([outer]))
    XCTAssertEqual(pending.visible, [outer]); XCTAssertEqual(pending.retired, obsolete)
    let complete = TerrainCoverage(desired: target, available: target.union(obsolete).union([outer]))
    XCTAssertEqual(complete.visible, target); assertDisjoint(complete.visible)
    XCTAssertEqual(complete.retired, obsolete.union([outer]))
    let coarsening = TerrainCoverage(desired: [small], available: [surface, voxel])
    XCTAssertEqual(coarsening.visible, [voxel]); XCTAssertEqual(coarsening.retired, [surface])
  }

  /// Independent copy of the pre-reuse selector. Keep the old target/index
  /// construction here so equivalence does not just compare two cached calls.
  private func originalPlan(target: Set<TerrainTile>, visible: Set<TerrainTile>,
    center: ChunkCoordinate) -> Set<TerrainTile> {
    let targetIndex = TerrainOverlapIndex(target), visibleIndex = TerrainOverlapIndex(visible)
    let roots = Set(target.map { TerrainTile(x: floorDivide($0.x, by: 32) * 32,
      z: floorDivide($0.z, by: 32) * 32, size: 32) })
    var next: Set<TerrainTile> = []
    func children(_ tile: TerrainTile) -> [TerrainTile] {
      let half = tile.size / 2
      return [.init(x: tile.x, z: tile.z, size: half), .init(x: tile.x + half, z: tile.z, size: half),
        .init(x: tile.x, z: tile.z + half, size: half), .init(x: tile.x + half, z: tile.z + half, size: half)]
    }
    func visit(_ tile: TerrainTile) {
      let final = targetIndex.overlapping(tile)
      guard !final.isEmpty else { return }
      if target.contains(tile) { next.insert(tile); return }
      if tile.size == 1 { next.formUnion(final); return }
      if visible.contains(tile) {
        if final.count <= 8 { next.formUnion(final) }
        else {
          for child in children(tile) where targetIndex.containsOverlap(with: child) {
            if child.size == 1 { next.formUnion(targetIndex.overlapping(child)) }
            else { next.insert(child) }
          }
        }
      } else if visibleIndex.containsOverlap(with: tile) || tile.distanceSquared(to: center) <= 4 {
        for child in children(tile) { visit(child) }
      } else { next.insert(tile) }
    }
    for root in roots { visit(root) }
    return next
  }

  private func assertDisjoint(_ tiles: Set<TerrainTile>, file: StaticString = #filePath, line: UInt = #line) {
    let index = TerrainOverlapIndex(tiles)
    for tile in tiles {
      XCTAssertEqual(index.overlapping(tile).count, 1, "Overlapping coverage at \(tile)", file: file, line: line)
    }
  }
}
