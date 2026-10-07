import Foundation
import XCTest
@testable import WorldCore

final class TerrainFeatureInspectionTests: XCTestCase, @unchecked Sendable {
  private struct Fixture {
    let world: UUID
    var registry: TerrainSurfaceSources
    let visible: Set<TerrainTile>
    let snapshot: TerrainSurfaceSources.Snapshot
    let source: TerrainSurfaceSeam.Source
    let mask: VoxelColumnMask
    let terrain = TerrainGenerator(seed: 91, style: .dune)
    func request(_ sequence: UInt64, sources: [ChunkCoordinate: TerrainSurfaceSeam.Source]? = nil,
      world: UUID? = nil) -> TerrainFeatureInspectionRequest {
      .init(world: world ?? self.world, revision: 0, sequence: sequence, terrain: terrain, ground: snapshot,
        domain: [source.chunk.coordinate: mask], sources: sources ?? [source.chunk.coordinate: source], fluids: .retainedSeparately)
    }
  }
  private func grid(_ tile: TerrainTile, height: Float = 8) -> TerrainSurfaceGrid {
    let side = tile.blockSize / tile.sampleStride + 1
    return .init(tile: tile, heights: .init(repeating: height, count: side*side),
      materials: .init(repeating: .stone, count: (side-1)*(side-1)))!
  }
  private func fixture(nearEast: Bool = false) -> Fixture {
    let world = UUID()
    var registry = TerrainSurfaceSources(), visible = Set<TerrainTile>()
    for z in -1...1 { for x in -1...1 {
      let tile = TerrainTile(x: x, z: z, fullDetail: nearEast && x == 1 && z == 0)
      visible.insert(tile)
      if !tile.fullDetail { registry.install(id: .init(world: world, tile: tile, revision: 0, lush: false), grid: grid(tile)) }
    } }
    var chunk = ChunkData(coordinate: .init(0,0))
    for z in -1...16 { for x in -1...16 { for y in ChunkData.minimumY..<8 { chunk[x,y,z] = .stone } } }
    for x in -1...3 { for y in 2...5 { chunk[x,y,5] = .air } }
    chunk[4,7,0] = .glass; chunk[8,6,15] = .water; chunk[12,7,0] = .woodStairsEast
    var mask = VoxelColumnMask(); mask.include(x: 0..<16, z: 0..<16)
    return .init(world: world, registry: registry, visible: visible, snapshot: registry.snapshot(visible: visible)!,
      source: .init(chunk), mask: mask)
  }
  private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<400 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
  }

  func testReadLeaseSurvivesUnrelatedStreamingButNotReplacementOfUsedSources() throws {
    var f = fixture()
    let tile = TerrainTile(x: 0, z: 0), far = TerrainTile(x: 16, z: 16, size: 8)
    let lease = f.snapshot.dependencies(for: [.init(0,0)])
    XCTAssertEqual(lease.coarseCount, 1); XCTAssertLessThan(lease.byteCount, f.snapshot.byteCount)
    f.registry.install(id: .init(world: f.world, tile: far, revision: 0, lush: false), grid: grid(far))
    let changed = f.visible.union([far])
    XCTAssertTrue(f.registry.isCurrent(lease, visible: changed))
    XCTAssertFalse(f.registry.isCurrent(f.snapshot, visible: changed))
    f.registry.install(id: .init(world: f.world, tile: .init(x: 1, z: 1), revision: 9, lush: false), grid: grid(.init(x: 1, z: 1)))
    XCTAssertTrue(f.registry.isCurrent(lease, visible: changed))
    f.registry.install(id: .init(world: f.world, tile: tile, revision: 0, lush: false), grid: grid(tile, height: 40))
    XCTAssertFalse(f.registry.isCurrent(lease, visible: changed), "Reusing a work ID cannot reuse a source lifetime")
  }

  func testReadLeaseTracksFineOwnershipMissingCoverageAndReset() throws {
    var f = fixture(nearEast: true)
    let fine = TerrainTile(x: 1, z: 0, fullDetail: true), gap = TerrainTile(x: 10, z: 10)
    let fineLease = f.snapshot.dependencies(for: [fine.coordinate]), gapLease = f.snapshot.dependencies(for: [gap.coordinate])
    XCTAssertEqual(fineLease.fineCount, 1); XCTAssertEqual(gapLease.missingCount, 1)
    XCTAssertTrue(f.registry.isCurrent(fineLease, visible: f.visible))
    XCTAssertFalse(f.registry.isCurrent(fineLease, visible: f.visible.subtracting([fine])))
    XCTAssertTrue(f.registry.isCurrent(gapLease, visible: f.visible))
    XCTAssertFalse(f.registry.isCurrent(gapLease, visible: f.visible.union([gap])))
    let merged = try XCTUnwrap(fineLease.merging(gapLease))
    XCTAssertEqual(merged.fineCount, 1); XCTAssertEqual(merged.missingCount, 1)
    let empty = f.snapshot.dependencies(for: [])
    f.registry.reset()
    XCTAssertFalse(f.registry.isCurrent(merged, visible: f.visible)); XCTAssertFalse(f.registry.isCurrent(empty, visible: []))
  }

  func testLeaseMergeRejectsConflictingVersionsAndOwnership() throws {
    var f = fixture()
    let tile = TerrainTile(x: 0, z: 0), old = f.snapshot.dependencies(for: [tile.coordinate])
    f.registry.install(id: .init(world: f.world, tile: tile, revision: 1, lush: false), grid: grid(tile))
    let next = try XCTUnwrap(f.registry.snapshot(visible: f.visible)).dependencies(for: [tile.coordinate])
    XCTAssertNil(old.merging(next))
    let fine = TerrainTile(x: 0, z: 0, fullDetail: true), visible = f.visible.subtracting([tile]).union([fine])
    let detailed = try XCTUnwrap(f.registry.snapshot(visible: visible)).dependencies(for: [tile.coordinate])
    XCTAssertNil(next.merging(detailed))
    let missing = try XCTUnwrap(f.registry.snapshot(visible: f.visible.subtracting([tile]))).dependencies(for: [tile.coordinate])
    XCTAssertNil(next.merging(missing)); XCTAssertNil(detailed.merging(missing))
    XCTAssertNil(old.merging(fixture().snapshot.dependencies(for: [])))
  }

  func testInspectionMatchesMeshDiagnosticsAndTracksSuppressedNearEdges() throws {
    var f = fixture(nearEast: true), cache = TerrainSurfaceSeam.InspectionCache()
    let input = f.request(1), value = TerrainFeatureInspection.prepare(input, cache: &cache)
    XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.inspections.count, 1)
    let boundary = VoxelColumnBoundary(columns: f.mask) { x,z in
      (0..<16).contains(x) && (0..<16).contains(z) || x == 16 && (0..<16).contains(z)
    }
    let reference = try XCTUnwrap(TerrainSurfaceSeam.build(f.source.chunk, boundary: boundary, fluids: .retainedSeparately) { edge in
      let n = edge.neighbor, point = BlockPosition(n.x,0,n.z)
      let source = f.snapshot.source(containing: point.chunk)!, tile = source.id.tile
      let sampler = TerrainSurface.Sampler(tile: tile, terrain: f.terrain)
      return source.grid.segments(atLocalX: point.x-tile.x*16, z: point.z-tile.z*16,
        face: edge.face ^ 1, referenceHeight: sampler.column(point.x,point.z).height)!
    })
    XCTAssertEqual(value.inspections[.init(0,0)], reference.inspection)
    XCTAssertFalse(reference.cavityCells.isEmpty); XCTAssertFalse(reference.unsupportedCells.isEmpty)
    XCTAssertFalse(reference.fluidBoundaryCells.isEmpty, "Ready inspection must retain unresolved dependencies")
    XCTAssertEqual(value.groundLease.fineCount, 1, "The fine neighbour suppressed an edge but still affected the result")
    XCTAssertTrue(f.registry.isCurrent(value.groundLease, visible: f.visible))
    let near = TerrainTile(x: 1, z: 0, fullDetail: true)
    XCTAssertFalse(f.registry.isCurrent(value.groundLease, visible: f.visible.subtracting([near])))
    // Changing the parent containing the patch itself matters even if all
    // segment queries were served by the neighbouring coarse tiles.
    let owner = TerrainTile(x: 0, z: 0)
    f.registry.install(id: .init(world: f.world, tile: owner, revision: 1, lush: false), grid: grid(owner))
    XCTAssertFalse(f.registry.isCurrent(value.groundLease, visible: f.visible))
  }

  func testInspectionLimitsCancellationAndMissingInputsNeverReturnPartialReadyData() {
    let f = fixture(), input = f.request(1)
    var cache = TerrainSurfaceSeam.InspectionCache()
    for limit in [TerrainFeatureInspectionLimits(inputBytes: 0), .init(outputBytes: 0), .init(chunks: 0), .init(columns: 255)] {
      let value = TerrainFeatureInspection.prepare(input, limits: limit, cache: &cache)
      XCTAssertTrue([.inputLimit,.outputLimit].contains(value.status)); XCTAssertTrue(value.inspections.isEmpty)
      XCTAssertTrue(value.exterior.isEmpty); XCTAssertEqual(value.byteCount, 0)
    }
    XCTAssertEqual(TerrainFeatureInspection.prepare(f.request(1,sources: [:]), cache: &cache).status, .missingChunk)
    let wrong = TerrainSurfaceSeam.Source(ChunkData(coordinate: .init(2,0)))
    XCTAssertEqual(TerrainFeatureInspection.prepare(f.request(1,sources: [.init(0,0):wrong]), cache: &cache).status, .invalidInput)
    XCTAssertEqual(TerrainFeatureInspection.prepare(f.request(1,world: UUID()), cache: &cache).status, .invalidInput)
    var calls = 0
    let cancelled = TerrainFeatureInspection.prepare(input, cache: &cache) { calls += 1; return calls > 8 }
    XCTAssertEqual(cancelled.status, .cancelled); XCTAssertTrue(cancelled.inspections.isEmpty)
    XCTAssertTrue(cancelled.exterior.isEmpty); XCTAssertEqual(cancelled.byteCount, 0)
    var ownerOnly = f.registry
    let owner = TerrainTile(x: 0,z: 0)
    let snapshot = ownerOnly.snapshot(visible: [owner])!
    let missing = TerrainFeatureInspectionRequest(world: f.world, revision: 0, sequence: 1, terrain: f.terrain,
      ground: snapshot, domain: input.domain, sources: input.sources, fluids: .retainedSeparately)
    XCTAssertEqual(TerrainFeatureInspection.prepare(missing, cache: &cache).status, .missingGround)
    ownerOnly.reset()
  }

  private final class Gate: @unchecked Sendable {
    let condition = NSCondition()
    private var entered = false, released = false, entries = 0
    var hasEntered: Bool { condition.withLock { entered } }
    func pauseFirst() {
      condition.lock(); entries += 1
      if entries == 1 { entered = true; condition.broadcast(); while !released { condition.wait() } }
      condition.unlock()
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
  }

  @MainActor func testActorCoalescesRapidDemandWhileMainActorRemainsResponsive() async throws {
    let f = fixture(), gate = Gate(), limits = TerrainFeatureInspectionLimits()
    let service = TerrainFeatureInspectionService(limits: limits) { input, limits, cache, cancelled in
      gate.pauseFirst()
      return TerrainFeatureInspection.prepare(input, limits: limits, cache: &cache, isCancelled: cancelled)
    }
    defer { gate.release() }
    service.expect(world: f.world, revision: 0); service.submit(f.request(1))
    let started = await eventually { gate.hasEntered }; XCTAssertTrue(started)
    for sequence in 2...501 { XCTAssertEqual(service.submit(f.request(UInt64(sequence))), .accepted) }
    XCTAssertTrue(service.metrics.running); XCTAssertTrue(service.metrics.pending)
    XCTAssertEqual(service.metrics.runningBytes, f.request(1).byteCount)
    XCTAssertEqual(service.metrics.pendingBytes, f.request(501).byteCount)
    XCTAssertGreaterThanOrEqual(service.metrics.coalesced, 499)
    let heartbeat = Task { @MainActor in 17 }
    let beat = await heartbeat.value; XCTAssertEqual(beat, 17)
    XCTAssertNil(service.latest)
    gate.release()
    let ready = await eventually { service.latest?.sequence == 501 }; XCTAssertTrue(ready)
    XCTAssertEqual(service.latest?.status, .ready); XCTAssertEqual(service.metrics.completed, 1)
    XCTAssertEqual(service.metrics.discarded, 1); XCTAssertEqual(service.metrics.mainThreadViolations, 0)
    XCTAssertLessThanOrEqual(service.metrics.readyBytes, limits.outputBytes)
    XCTAssertLessThanOrEqual(service.metrics.cacheBytes, 4*1_024*1_024)
  }

  func testResetRejectsSameSequenceFromPreviousLifetime() async throws {
    let f = fixture(), gate = Gate()
    let service = TerrainFeatureInspectionService(limits: .init()) { input, limits, cache, cancelled in
      gate.pauseFirst()
      return TerrainFeatureInspection.prepare(input, limits: limits, cache: &cache, isCancelled: cancelled)
    }
    defer { gate.release() }
    service.expect(world: f.world, revision: 0); service.submit(f.request(1))
    let started = await eventually { gate.hasEntered }; XCTAssertTrue(started)
    service.expect(world: f.world, revision: 0); service.submit(f.request(1))
    gate.release()
    let ready = await eventually { service.latest != nil }; XCTAssertTrue(ready)
    XCTAssertEqual(service.metrics.discarded, 1); XCTAssertEqual(service.metrics.completed, 1)
    XCTAssertEqual(service.latest?.status, .ready); XCTAssertEqual(service.metrics.mainThreadViolations, 0)
  }

  func testNewerOversizeDemandInvalidatesReadyWorkAndCanRecover() async throws {
    let f = fixture(), input = f.request(1)
    let service = TerrainFeatureInspectionService(limits: .init(inputBytes: input.byteCount))
    service.expect(world: f.world, revision: 0); service.submit(input)
    let first = await eventually { service.latest?.sequence == 1 }; XCTAssertTrue(first)
    let original = try XCTUnwrap(service.latest)
    var sources = input.sources; sources[.init(2,0)] = .init(ChunkData(coordinate: .init(2,0)))
    XCTAssertEqual(service.submit(f.request(2,sources: sources)), .inputLimit)
    XCTAssertNil(service.latest); XCTAssertEqual(service.metrics.readyBytes, 0); XCTAssertFalse(service.metrics.pending)
    XCTAssertEqual(service.submit(f.request(1)), .stale)
    XCTAssertEqual(service.submit(f.request(3)), .accepted)
    let ready = await eventually { service.latest?.sequence == 3 }; XCTAssertTrue(ready)
    XCTAssertEqual(service.latest?.inspections, original.inspections)
    XCTAssertEqual(service.latest?.exterior, original.exterior)
    XCTAssertGreaterThan(service.metrics.cacheHits, 0); XCTAssertEqual(service.metrics.refused, 1)
    XCTAssertFalse(service.metrics.running); XCTAssertEqual(service.metrics.runningBytes, 0)
  }
}
