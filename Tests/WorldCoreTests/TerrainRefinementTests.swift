import CryptoKit
import Foundation
import XCTest
@testable import WorldCore

final class TerrainRefinementTests: XCTestCase, @unchecked Sendable {
  private func profile(low: Float = 0, high: Float = 100, error: Float = 12) -> TerrainSurfaceProfile {
    .init(minimumY: low, maximumY: high, sampledHeightError: error, sampleCount: 3_136)
  }
  private func cells(_ tiles: Set<TerrainTile>) -> [ChunkCoordinate: Int] {
    var result: [ChunkCoordinate: Int] = [:]
    for tile in tiles {
      for z in tile.z..<(tile.z + tile.size) { for x in tile.x..<(tile.x + tile.size) {
        result[.init(x, z), default: 0] += 1
      } }
    }
    return result
  }

  func testResidualUsesActualTrianglesAndDetectsUnsampledPeak() throws {
    let tile = TerrainTile(x: -16, z: 0, size: 8), side = tile.blockSize / tile.sampleStride + 1
    func plane(_ x: Int, _ z: Int) -> Float { Float(2 * x - z + 10) }
    let heights = (0..<side).flatMap { z in (0..<side).map { x in plane(x * 4, z * 4) } }
    let flat = try XCTUnwrap(TerrainSurfaceProfile.measure(tile: tile, heights: heights, sample: plane))
    XCTAssertEqual(flat.sampledHeightError, 0); XCTAssertGreaterThan(flat.sampleCount, 3_000)
    let peak = try XCTUnwrap(TerrainSurfaceProfile.measure(tile: tile, heights: heights) { x, z in
      plane(x, z) + (x == 2 && z == 2 ? 25 : 0)
    })
    XCTAssertEqual(peak.sampledHeightError, 25)
    let stepped = TerrainTile(x: -4, z: -4, size: 4)
    let steppedProfile = try XCTUnwrap(TerrainSurfaceProfile.measure(tile: stepped,
      heights: (0..<side).flatMap { z in (0..<side).map { x in plane(x * 2, z * 2) } }, sample: plane))
    XCTAssertGreaterThan(steppedProfile.sampledHeightError, 0, "Block tops are not sloped triangles")
  }

  func testProfileAddsNoGeometryChangesAndContainsReferenceAndExplicitStructures() throws {
    for style in PlanetStyle.allCases {
      let tile = TerrainTile(x: -16, z: 16, size: 8)
      let terrain = TerrainGenerator(seed: 967_252_643, style: style)
      let edits: [BlockPosition: Block] = [.init(-200, 120, 290): .brick]
      let a = TerrainSurface.build(tile, terrain: terrain, edits: edits, measureError: false)
      let b = TerrainSurface.build(tile, terrain: terrain, edits: edits)
      XCTAssertNil(a.profile)
      let p = try XCTUnwrap(b.profile)
      XCTAssertTrue(p.isValid)
      XCTAssertEqual(a.mesh.positions, b.mesh.positions); XCTAssertEqual(a.mesh.normals, b.mesh.normals)
      XCTAssertEqual(a.mesh.textureCoordinates, b.mesh.textureCoordinates)
      XCTAssertEqual(a.mesh.indices, b.mesh.indices); XCTAssertEqual(a.mesh.materials, b.mesh.materials)
      XCTAssertEqual(a.water, b.water)
      XCTAssertLessThanOrEqual(p.minimumY, b.mesh.positions.map(\.y).min()!)
      XCTAssertGreaterThanOrEqual(p.maximumY, b.mesh.positions.map(\.y).max()!)
      XCTAssertGreaterThanOrEqual(p.maximumY, 121)
    }
  }

  func testHeightAndThreeDimensionalBoundsChangePriority() {
    let low = TerrainTile(x: -4, z: 0, size: 4), high = TerrainTile(x: 0, z: 0, size: 4)
    let profiles = [low: profile(low: 0, high: 30), high: profile(low: 450, high: 500)]
    let ground = TerrainRefinementPlan(base: [low, high], profiles: profiles, eye: [0, 15, 64], maximumExtraTiles: 3)
    XCTAssertEqual(ground.splits, [low])
    let elevated = TerrainRefinementPlan(base: [low, high], profiles: profiles, eye: [0, 490, 64], maximumExtraTiles: 3)
    XCTAssertEqual(elevated.splits, [high])
    let space = TerrainRefinementPlan(base: [low, high], profiles: profiles, eye: [0, 20_000, 64])
    XCTAssertEqual(space.tiles, [low, high], "Preserve baseline quality even when high above its bounds")
    XCTAssertEqual(profile(error: 0).projectedError(for: low, eye: [-20, 20, 20]), 0)
    XCTAssertFalse(profile(low: 10, high: 0).isValid)
  }

  func testCanopySupportCanRefineFlatTerrainWithoutShrinkingFootprint() {
    let forest=TerrainTile(x:0,z:0,size:8),plain=TerrainTile(x:8,z:0,size:8)
    let canopy=TerrainSurfaceProfile(minimumY:20,maximumY:60,sampledHeightError:0,sampleCount:0,groupedCanopyExtent:35)
    let flat=TerrainSurfaceProfile(minimumY:20,maximumY:60,sampledHeightError:0,sampleCount:0)
    let eye=SIMD3<Float>(64,45,-300)
    XCTAssertEqual(canopy.projectedError(for:forest,eye:eye),35/300,accuracy:0.00001)
    let plan=TerrainRefinementPlan(base:[forest,plain],profiles:[forest:canopy,plain:flat],eye:eye,maximumExtraTiles:15)
    XCTAssertTrue(plan.splits.contains(forest));XCTAssertFalse(plan.splits.contains(plain))
    XCTAssertEqual(cells(plan.tiles),cells([forest,plain]))
    XCTAssertFalse(TerrainSurfaceProfile(minimumY:0,maximumY:1,sampledHeightError:0,sampleCount:0,groupedCanopyExtent:.infinity).isValid)
    XCTAssertFalse(TerrainSurfaceProfile(minimumY:0,maximumY:1,sampledHeightError:0,sampleCount:0,groupedCanopyExtent:-1).isValid)
  }

  func testMeasuredGroupedCanopyIncludesIndividualTreeHeightAndPreservesGeometry() throws {
    let terrain=TerrainGenerator(seed:967252643)
    var found=false
    for (x,z) in [(0,32),(16,48),(-32,32),(32,48)] {
      let tile=TerrainTile(x:x,z:z,size:8)
      let old=TerrainSurface.build(tile,terrain:terrain,measureError:false)
      let new=TerrainSurface.build(tile,terrain:terrain)
      let profile=try XCTUnwrap(new.profile)
      XCTAssertEqual(old.mesh.positions,new.mesh.positions);XCTAssertEqual(old.mesh.indices,new.mesh.indices)
      XCTAssertEqual(old.mesh.textureCoordinates,new.mesh.textureCoordinates);XCTAssertEqual(old.water,new.water)
      XCTAssertTrue(profile.isValid)
      if profile.groupedCanopyExtent > 0 {
        found=true
        // A group's x/z span is at most grouping-1 plus two maximum radii
        // and one block; its vertical span fits the finite world.
        let side=Float(tile.size+8),height=Float(ChunkData.height-ChunkData.minimumY)
        XCTAssertLessThanOrEqual(profile.groupedCanopyExtent,(2*side*side+height*height).squareRoot())
      }
      let fine=TerrainSurface.build(.init(x:x,z:z,size:2),terrain:terrain)
      XCTAssertEqual(fine.profile?.groupedCanopyExtent,0,"Ungrouped trees must not inherit the coarse support extent")
    }
    XCTAssertTrue(found,"Fixture must contain grouped forest")
    XCTAssertEqual(TerrainSurface.build(.init(x:0,z:0,size:32),terrain:.init(seed:967252643,style:.dune)).profile?.groupedCanopyExtent,0)
  }

  func testCanopyMetadataArchiveRoundTripAndOrdinaryCacheIdentity() throws {
    let tile=TerrainTile(x:0,z:32,size:8),terrain=TerrainGenerator(seed:967252643)
    let id=TerrainWorkID(world:UUID(),tile:tile,revision:0,lush:false,profileSurface:true)
    let request=TerrainPreparationRequest(id:id,terrain:terrain,service:.refinement,priority:0)
    let payload=try XCTUnwrap(TerrainPreparation.build(request,collision:{_ in}))
    let key=TerrainPayloadKey(request)
    XCTAssertEqual(key.representationVersion,15)
    let encoded=try XCTUnwrap(TerrainPayloadCodec.encode(payload,key:key))
    let decoded=try XCTUnwrap(TerrainPayloadCodec.decode(encoded,key:key,id:id))
    XCTAssertEqual(decoded.surfaceProfile,payload.surfaceProfile)
    XCTAssertGreaterThan(try XCTUnwrap(decoded.surfaceProfile).groupedCanopyExtent,0)
    let ordinary=TerrainPreparationRequest(id:.init(world:id.world,tile:tile,revision:0,lush:false),terrain:terrain,service:.refinement,priority:0)
    XCTAssertEqual(TerrainPayloadKey(ordinary).representationVersion,13)
    let addition:[BlockPosition:Block]=[.init(tile.x*16+1,100,tile.z*16+1):.wood]
    XCTAssertEqual(TerrainPayloadKey(.init(id:ordinary.id,terrain:terrain,edits:addition,service:.refinement,priority:0)).representationVersion,14)
    XCTAssertEqual(TerrainPayloadKey(.init(id:id,terrain:terrain,edits:addition,service:.refinement,priority:0)).representationVersion,16)
  }

  func testRefinementPreservesWholeFootprintAndNearContractWithinBudget() {
    for center in [ChunkCoordinate(19, 51), .init(-67, -31)] {
      let base = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16).tiles
      var profiles = [TerrainTile: TerrainSurfaceProfile]()
      func populate(_ tile: TerrainTile) {
        guard !tile.fullDetail else { return }
        profiles[tile] = profile(error: Float(tile.size) * 100)
        guard tile.size > 2 else { return }
        let half = tile.size / 2
        for dz in [0, half] { for dx in [0, half] { populate(.init(x: tile.x + dx, z: tile.z + dz, size: half)) } }
      }
      for tile in base { populate(tile) }
      let plan = TerrainRefinementPlan(base: base, profiles: profiles, eye: center.origin + [0, 100, 0])
      XCTAssertEqual(plan.tiles.count, base.count + 96)
      XCTAssertEqual(plan.splits.count, 32)
      XCTAssertEqual(cells(plan.tiles), cells(base)); XCTAssertTrue(cells(plan.tiles).values.allSatisfy { $0 == 1 })
      XCTAssertEqual(plan.tiles.filter(\.fullDetail), base.filter(\.fullDetail))
      XCTAssertEqual(TerrainRefinementPlan.retaining(plan.splits, in: base), plan.tiles)
      XCTAssertEqual(TerrainRefinementPlan.retaining(plan.splits, in: []), [])
      let shuffled = Dictionary(uniqueKeysWithValues: profiles.sorted { $0.key.x < $1.key.x }.reversed())
      XCTAssertEqual(TerrainRefinementPlan(base: base, profiles: shuffled, eye: center.origin + [0, 100, 0]).tiles, plan.tiles)
      let coverage = TerrainCoverage(desired: plan.tiles, available: base)
      XCTAssertEqual(cells(coverage.visible), cells(base), "Refinement cannot remove visible parents early")
      let ready = TerrainCoverage(desired: plan.tiles, available: base.union(plan.tiles))
      XCTAssertEqual(ready.visible, plan.tiles)
    }
  }

  func testHysteresisAndMissingEditedParentKeepSelectedDetail() {
    let tile = TerrainTile(x: 0, z: 0, size: 8), p = profile(low: 0, high: 0, error: 1)
    let initial = TerrainRefinementPlan(base: [tile], profiles: [tile: p], eye: [64, 99, 64])
    XCTAssertTrue(initial.splits.contains(tile))
    let nearBoundary = TerrainRefinementPlan(base: [tile], profiles: [tile: p], eye: [64, 115, 64], previousSplits: initial.splits)
    XCTAssertEqual(nearBoundary.splits, initial.splits)
    XCTAssertTrue(TerrainRefinementPlan(base: [tile], profiles: [tile: p], eye: [64, 115, 64]).splits.isEmpty)
    XCTAssertTrue(TerrainRefinementPlan(base: [tile], profiles: [tile: p], eye: [64, 150, 64], previousSplits: initial.splits).splits.isEmpty)
    let unknown = TerrainRefinementPlan(base: [tile], profiles: [:], eye: [64, 115, 64], previousSplits: initial.splits)
    XCTAssertEqual(unknown.splits, initial.splits); XCTAssertEqual(unknown.unresolvedLeaves, 16)
    XCTAssertTrue(TerrainRefinementPlan(base: [tile], profiles: [:], eye: .zero).splits.isEmpty)
  }

  func testSmoothToBlockTransitionReservesTrueBlockSurfaceBeforeSpendingBudget() {
    let tile = TerrainTile(x: -8, z: -8, size: 8)
    let insufficient = TerrainRefinementPlan(base: [tile], profiles: [tile: profile()],
      eye: [-64, 30, -64], maximumExtraTiles: 12)
    XCTAssertEqual(insufficient.tiles, [tile])
    let ready = TerrainRefinementPlan(base: [tile], profiles: [tile: profile()],
      eye: [-64, 30, -64], maximumExtraTiles: 15)
    XCTAssertEqual(ready.tiles.count, 16); XCTAssertEqual(ready.splits.count, 5)
    XCTAssertTrue(ready.tiles.allSatisfy { $0.size == 2 && $0.sampleStride == 1 })
    XCTAssertEqual(cells(ready.tiles), cells([tile]))
    XCTAssertEqual(TerrainRefinementPlan.retaining(ready.splits, in: [tile]), ready.tiles)
  }

  func testMetadataIsBoundedAndEditsInvalidateNegativeCoordinateAncestorsOnly() {
    var cache = TerrainSurfaceProfiles(limit: 6)
    for size in [1, 2, 4, 8, 16, 32] { cache.insert(profile(), for: .init(x: -size, z: -size, size: size)) }
    XCTAssertEqual(cache.values.count, 6)
    let remote = TerrainTile(x: 32, z: 32, size: 32)
    cache.insert(profile(), for: remote)
    XCTAssertEqual(cache.values.count, 6)
    XCTAssertNil(cache.values[.init(x: -1, z: -1)])
    let snapshot = cache.values
    cache.invalidate([.init(-1, -1)])
    XCTAssertEqual(cache.values.keys.sorted { $0.x < $1.x }, [remote])
    XCTAssertEqual(snapshot.count, 6, "Worker snapshots must remain immutable during scene edits")
    cache.insert(profile(low: 30, high: 0), for: .init(x: 64, z: 64, size: 32))
    XCTAssertEqual(cache.values.count, 1)
  }

  func testProfileSurvivesCacheArchiveAndNewLifecycleAndRejectsInvalidMetadata() throws {
    let id = TerrainWorkID(world: UUID(), tile: .init(x: -32, z: 0, size: 16), revision: 0, lush: false, profileSurface: true)
    let request = TerrainPreparationRequest(id: id, terrain: .init(seed: 91, style: .dune), service: .coverage, priority: 0)
    let result = try XCTUnwrap(TerrainPreparation.build(request, collision: { _ in }))
    let key = TerrainPayloadKey(request)
    XCTAssertNotNil(result.surfaceProfile)
    let ordinaryID = TerrainWorkID(world: id.world, tile: id.tile, revision: 0, lush: false)
    let ordinaryRequest = TerrainPreparationRequest(id: ordinaryID, terrain: request.terrain, service: .coverage, priority: 0)
    XCTAssertNotEqual(TerrainPayloadKey(ordinaryRequest), key)
    let ordinary = try XCTUnwrap(TerrainPreparation.build(ordinaryRequest, collision: { _ in }))
    XCTAssertNil(ordinary.surfaceProfile, "Disabled pilot must not pay for profiling")
    let archive = try XCTUnwrap(TerrainPayloadCodec.encode(result, key: key))
    let next = TerrainWorkID(world: UUID(), tile: id.tile, revision: 4, lush: false, profileSurface: true)
    let decoded = try XCTUnwrap(TerrainPayloadCodec.decode(archive, key: key, id: next))
    XCTAssertEqual(decoded.surfaceProfile, result.surfaceProfile)
    XCTAssertEqual(decoded.reissued(id: next, stages: [:]).surfaceProfile, result.surfaceProfile)
    XCTAssertEqual(decoded.byteCount, result.byteCount)
    for bad in [profile(low: .nan), profile(high: -.infinity), profile(error: -1), profile(low: 50, high: 1)] {
      XCTAssertNil(TerrainPayloadCodec.encode(.init(id: id, mesh: result.mesh, surfaceProfile: bad), key: key))
    }
  }

  func testLateActorOutputCannotSurviveWorldEditOrTravel() async throws {
    let service = TerrainRefinementService(), world = UUID(), tile = TerrainTile(x: 0, z: 0, size: 32)
    func request(_ sequence: UInt64, revision: UInt64 = 0, world: UUID) -> TerrainRefinementObservation {
      .init(world: world, revision: revision, sequence: sequence, base: [tile], previousSplits: [], profiles: [tile: profile()], eye: .zero)
    }
    service.expect(world: world, revision: 0)
    for n in 1...300 { service.submit(request(UInt64(n), world: world)) }
    for _ in 0..<200 {
      if service.latest?.input.sequence == 300 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let old = try XCTUnwrap(service.latest)
    XCTAssertEqual(old.input.sequence, 300); XCTAssertEqual(service.metrics.mainThreadViolations, 0)
    service.expect(world: world, revision: 1)
    service.publish(old); service.submit(request(301, world: world))
    XCTAssertNil(service.latest)
    service.submit(request(302, revision: 1, world: world))
    for _ in 0..<200 {
      if service.latest?.input.sequence == 302 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(service.latest?.input.revision, 1)
    service.expect(world: UUID(), revision: 0)
    service.publish(old)
    XCTAssertNil(service.latest)
  }
}

final class TerrainSurfaceSourceTests: XCTestCase, @unchecked Sendable {
  private func grid(_ tile: TerrainTile, height: Float = 24, material: Block = .stone) -> TerrainSurfaceGrid {
    let side = tile.blockSize / tile.sampleStride + 1
    return TerrainSurfaceGrid(tile: tile, heights: .init(repeating: height, count: side * side),
      materials: .init(repeating: material, count: (side - 1) * (side - 1)))!
  }
  private func id(_ tile: TerrainTile, world: UUID, revision: Int = 0) -> TerrainWorkID {
    .init(world: world, tile: tile, revision: revision, lush: false)
  }

  func testCapturedCellsMatchRenderedTopTrianglesAndPreserveAllGeometry() throws {
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 967_252_643, style: style)
      for size in [1, 2, 4, 8, 16, 32] {
        let tile = TerrainTile(x: -size, z: size, size: size)
        let edits: [BlockPosition: Block] = [.init(-1, 130, size * 16 + 1): .brick]
        let original = TerrainSurface.build(tile, terrain: terrain, edits: edits)
        let retained = TerrainSurface.buildRetained(tile, terrain: terrain, edits: edits)
        XCTAssertEqual(original.mesh.positions, retained.mesh.positions)
        XCTAssertEqual(original.mesh.normals, retained.mesh.normals)
        XCTAssertEqual(original.mesh.textureCoordinates, retained.mesh.textureCoordinates)
        XCTAssertEqual(original.mesh.indices, retained.mesh.indices)
        XCTAssertEqual(original.mesh.materials, retained.mesh.materials)
        XCTAssertEqual(original.water, retained.water); XCTAssertEqual(original.profile, retained.profile)
        let grid = try XCTUnwrap(retained.grid)
        var tops = VoxelMesh()
        for z in stride(from: 0, to: tile.blockSize, by: tile.sampleStride) {
          for x in stride(from: 0, to: tile.blockSize, by: tile.sampleStride) {
            let cell = try XCTUnwrap(grid.cell(atLocalX: x, z: z))
            let i = tops.positions.count
            tops.appendQuad(cell.corners, normal: retained.mesh.normals[i], block: cell.material, face: 2, materialIndex: 0)
          }
        }
        XCTAssertEqual(tops.positions, Array(retained.mesh.positions.prefix(tops.positions.count)))
        XCTAssertEqual(tops.indices, Array(retained.mesh.indices.prefix(tops.indices.count)))
        XCTAssertEqual(tops.textureCoordinates, Array(retained.mesh.textureCoordinates.prefix(tops.textureCoordinates.count)))
      }
    }
  }

  func testQueriesFollowOriginalDiagonalAndOwnedSideOfSteps() throws {
    func saddle(_ tile: TerrainTile) -> TerrainSurfaceGrid {
      let base = grid(tile), side = base.side
      var heights = base.heights
      heights[0] = 10; heights[side] = 20; heights[side + 1] = 30; heights[1] = 50
      return .init(tile: tile, heights: heights, materials: base.materials)!
    }
    let slope = saddle(.init(x: -8, z: -8, size: 8))
    let cell = try XCTUnwrap(slope.cell(atLocalX: 1, z: 1))
    XCTAssertEqual(cell.height(atLocalX: 3, z: 1), 35)
    XCTAssertEqual(cell.height(atLocalX: 1, z: 3), 20)
    XCTAssertEqual(cell.height(atLocalX: 2, z: 2), 20)
    XCTAssertNil(cell.height(atLocalX: .nan, z: 0)); XCTAssertNil(cell.height(atLocalX: 5, z: 0))
    let seam = try XCTUnwrap(slope.segments(atLocalX: 1, z: 0, face: 0, referenceHeight: 99))
    XCTAssertEqual(seam, [.init(lower: 0, upper: 1, firstHeight: 30, lastHeight: 25,
      material: .stone, referenceHeight: 99)], "Uncarved reference is independent of the displayed coarse surface")
    let stepped = saddle(.init(x: -4, z: -4, size: 4))
    XCTAssertEqual(stepped.cell(atLocalX: 1, z: 1)?.heights, .init(repeating: 10))
    XCTAssertEqual(stepped.segments(atLocalX: 1, z: 0, face: 0, referenceHeight: 10)?.first?.firstHeight, 10)
    XCTAssertEqual(stepped.segments(atLocalX: 2, z: 0, face: 1, referenceHeight: 50)?.first?.firstHeight, 50)
    for face in [0, 1, 4, 5] {
      XCTAssertNotNil(slope.segments(atLocalX: 127, z: 127, face: face, referenceHeight: 24))
    }
  }

  func testInvalidGridsAndUnknownBoundaryEvidenceAreRejected() {
    let tile = TerrainTile(x: 0, z: 0, size: 8), valid = grid(tile)
    XCTAssertNil(TerrainSurfaceGrid(tile: .init(x: 0, z: 0, fullDetail: true), heights: [], materials: []))
    XCTAssertNil(TerrainSurfaceGrid(tile: tile, heights: Array(valid.heights.dropLast()), materials: valid.materials))
    XCTAssertNil(TerrainSurfaceGrid(tile: tile, heights: valid.heights, materials: Array(valid.materials.dropLast())))
    for bad in [Float.nan, .infinity, -.infinity] {
      var heights = valid.heights; heights[0] = bad
      XCTAssertNil(TerrainSurfaceGrid(tile: tile, heights: heights, materials: valid.materials))
      XCTAssertNil(valid.segments(atLocalX: 0, z: 0, face: 0, referenceHeight: bad))
    }
    for (x, z) in [(-1, 0), (0, -1), (128, 0), (0, 128)] {
      XCTAssertNil(valid.cell(atLocalX: x, z: z))
      XCTAssertNil(valid.segments(atLocalX: x, z: z, face: 0, referenceHeight: 24))
    }
    for face in [-1, 2, 3, 6] { XCTAssertNil(valid.segments(atLocalX: 0, z: 0, face: face, referenceHeight: 24)) }
    for material in [Block.air, .water, .leaves] {
      XCTAssertNil(grid(tile, material: material).segments(atLocalX: 0, z: 0, face: 0, referenceHeight: 24))
    }
    XCTAssertNil(grid(tile, height: Float(ChunkData.height + 1)).segments(atLocalX: 0, z: 0, face: 0, referenceHeight: 24))
  }

  func testPreparedCacheArchiveAndReissueKeepTheExactGroundSource() throws {
    let tile = TerrainTile(x: -16, z: 16, size: 8), world = UUID()
    for measured in [false, true] {
      let request = TerrainPreparationRequest(id: .init(world: world, tile: tile, revision: 0, lush: false,
        profileSurface: measured), terrain: .init(seed: 91, style: .dune), service: .coverage, priority: 0)
      let cache = TerrainPayloadCache()
      let built = try XCTUnwrap(TerrainPreparation.build(request, cache: cache, cullHidden: true, collision: { _ in }))
      let grid = try XCTUnwrap(built.surfaceGrid), key = TerrainPayloadKey(request)
      let newID = TerrainWorkID(world: UUID(), tile: tile, revision: 5, lush: false, incarnation: 20, profileSurface: measured)
      let cached = try XCTUnwrap(cache.value(for: key)).reissued(id: newID, stages: [:])
      let bytes = try XCTUnwrap(TerrainPayloadCodec.encode(built, key: key))
      let decoded = try XCTUnwrap(TerrainPayloadCodec.decode(bytes, key: key, id: newID))
      XCTAssertEqual(cached.id, newID); XCTAssertEqual(decoded.id, newID)
      XCTAssertEqual(cached.surfaceGrid, grid); XCTAssertEqual(decoded.surfaceGrid, grid)
      XCTAssertEqual(cached.byteCount, built.byteCount); XCTAssertEqual(decoded.byteCount, built.byteCount)
      let without = PreparedTerrainTile(id: built.id, mesh: built.mesh, animated: built.animated,
        windAdmissionVertexCount: built.windAdmissionVertexCount, stadiumSeats: built.stadiumSeats,
        surfaceProfile: built.surfaceProfile, water: built.water, plants: built.plants, lamps: built.lamps, fires: built.fires)
      XCTAssertEqual(built.byteCount - without.byteCount, grid.byteCount)
    }
    let fine = TerrainPreparationRequest(id: id(.init(x: 0, z: 0, fullDetail: true), world: world),
      terrain: .init(seed: 91), service: .detail, priority: 0)
    XCTAssertEqual(TerrainPayloadKey(fine).representationVersion, 9, "Existing full-detail cache identity is retained")
    XCTAssertNil(TerrainPreparation.build(fine, collision: { _ in })?.surfaceGrid)
  }

  func testArchiveRejectsInvalidGridMetadataEvenWithARepairedChecksum() throws {
    let tile = TerrainTile(x: 0, z: 0, size: 8), base = grid(tile)
    let heights = base.heights.indices.map { Float(100 + $0) / 13 }
    let value = try XCTUnwrap(TerrainSurfaceGrid(tile: tile, heights: heights, materials: base.materials))
    let request = TerrainPreparationRequest(id: id(tile, world: UUID()), terrain: .init(seed: 3), service: .coverage, priority: 0)
    let key = TerrainPayloadKey(request)
    let bytes = try XCTUnwrap(TerrainPayloadCodec.encode(.init(id: request.id, mesh: .init(.init()), surfaceGrid: value), key: key))
    let heightBytes = heights.withUnsafeBytes { Data($0) }
    let range = try XCTUnwrap(bytes.range(of: heightBytes))
    let materialsOffset = range.upperBound + 8 // Array count precedes its elements.
    var corruptions: [Data] = []
    var badHeight = bytes
    badHeight.replaceSubrange(range.lowerBound..<(range.lowerBound + 4), with: [0, 0, 128, 127]) // +infinity
    corruptions.append(badHeight)
    var badMaterial = bytes; badMaterial[materialsOffset] = 255; corruptions.append(badMaterial)
    var badLength = bytes; badLength[range.lowerBound - 8] ^= 1; corruptions.append(badLength)
    var oldSchema = bytes; oldSchema[40] = 4; corruptions.append(oldSchema)
    for var corrupt in corruptions {
      corrupt.replaceSubrange(8..<40, with: Data(SHA256.hash(data: corrupt.dropFirst(40))))
      XCTAssertNil(TerrainPayloadCodec.decode(corrupt, key: key, id: request.id))
    }
    XCTAssertNil(TerrainPayloadCodec.encode(.init(id: request.id, mesh: .init(.init()),
      surfaceGrid: grid(.init(x: 8, z: 0, size: 8))), key: key))
  }

  func testCoverageExchangeCapturesOnlyVisibleSourcesAndRejectsMixedWorlds() throws {
    let world = UUID(), parent = TerrainTile(x: -8, z: -8, size: 8)
    let children = Set([-8, -4].flatMap { z in [-8, -4].map { TerrainTile(x: $0, z: z, size: 4) } })
    var registry = TerrainSurfaceSources()
    registry.install(id: id(parent, world: world), grid: grid(parent))
    let original = try XCTUnwrap(registry.snapshot(visible: [parent]))
    XCTAssertEqual(original.world, world)
    XCTAssertEqual(original.source(containing: .init(-1, -1))?.id.tile, parent)
    XCTAssertNil(original.source(containing: .init(0, -1)))
    for child in children { registry.install(id: id(child, world: world), grid: grid(child, height: 30)) }
    XCTAssertTrue(registry.isCurrent(original, visible: [parent]), "Hidden preparation cannot invalidate unchanged displayed terrain")
    let newCoverage = TerrainCoverage(desired: children, available: children.union([parent])).visible
    XCTAssertEqual(newCoverage, children)
    let current = try XCTUnwrap(registry.snapshot(visible: newCoverage))
    XCTAssertFalse(registry.isCurrent(original, visible: newCoverage))
    XCTAssertEqual(current.source(containing: .init(-1, -1))?.id.tile, .init(x: -4, z: -4, size: 4))
    XCTAssertNil(registry.snapshot(visible: children.union([parent])), "Overlapping ownership cannot become source evidence")
    let child = children.first!
    registry.install(id: id(child, world: UUID()), grid: grid(child))
    XCTAssertNil(registry.snapshot(visible: children), "A snapshot must never mix planets")
    let fine = TerrainTile(x: 10, z: 10, fullDetail: true)
    let fineOnly = try XCTUnwrap(registry.snapshot(visible: [fine]))
    XCTAssertTrue(fineOnly.sources.isEmpty); XCTAssertNil(fineOnly.world)
    XCTAssertNil(fineOnly.source(containing: fine.coordinate))
  }

  func testCapacityMissingMetadataRemovalAndResetFailClosed() throws {
    let world = UUID(), first = TerrainTile(x: 0, z: 0, size: 8), second = TerrainTile(x: 8, z: 0, size: 8)
    let value = grid(first)
    for registryLimit in [TerrainSurfaceSources(limitEntries: 1, limitBytes: 1_000_000),
      TerrainSurfaceSources(limitEntries: 10, limitBytes: value.byteCount)] {
      var registry = registryLimit
      XCTAssertTrue(registry.install(id: id(first, world: world), grid: value))
      let snapshot = try XCTUnwrap(registry.snapshot(visible: [first]))
      XCTAssertFalse(registry.install(id: id(second, world: world), grid: grid(second)))
      XCTAssertEqual(registry.metrics.refused, 1); XCTAssertEqual(registry.metrics.bytes, value.byteCount)
      XCTAssertNil(registry.snapshot(visible: [first, second])); XCTAssertTrue(registry.isCurrent(snapshot, visible: [first]))
      XCTAssertFalse(registry.install(id: id(first, world: world, revision: 1), grid: nil))
      XCTAssertFalse(registry.isCurrent(snapshot, visible: [first])); XCTAssertNil(registry.snapshot(visible: [first]))
      XCTAssertEqual(snapshot.sources[first]?.grid, value, "Captured immutable arrays survive replacement")
      XCTAssertEqual(registry.metrics.bytes, 0)
      registry.install(id: id(first, world: world), grid: value)
      let current = try XCTUnwrap(registry.snapshot(visible: [first]))
      XCTAssertFalse(registry.isCurrent(snapshot, visible: [first]), "Same work ID reinstalled has a new source lifetime")
      registry.remove(first); XCTAssertFalse(registry.isCurrent(current, visible: [first]))
      let empty = try XCTUnwrap(registry.snapshot(visible: []))
      registry.reset(); XCTAssertFalse(registry.isCurrent(empty, visible: []))
      XCTAssertEqual(registry.metrics.bytes, 0); XCTAssertEqual(registry.metrics.entries, 0)
    }
    var disabled = TerrainSurfaceSources(limitEntries: 0, limitBytes: 0)
    XCTAssertFalse(disabled.install(id: id(first, world: world), grid: value))
    XCTAssertNil(disabled.snapshot(visible: [first]))
  }

  func testDetachedWorkKeepsImmutableDataButCannotPublishAfterReplacement() async throws {
    let world = UUID(), tile = TerrainTile(x: -8, z: 8, size: 8)
    var registry = TerrainSurfaceSources()
    registry.install(id: id(tile, world: world), grid: grid(tile, height: 24))
    let snapshot = try XCTUnwrap(registry.snapshot(visible: [tile]))
    let work = Task.detached {
      snapshot.sources[tile]?.grid.segments(atLocalX: 3, z: 2, face: 0, referenceHeight: 24)
    }
    registry.install(id: id(tile, world: world, revision: 1), grid: grid(tile, height: 80))
    let segments = await work.value
    XCTAssertEqual(segments?.first?.firstHeight, 24)
    XCTAssertFalse(registry.isCurrent(snapshot, visible: [tile]))
    let latest = try XCTUnwrap(registry.snapshot(visible: [tile]))
    XCTAssertEqual(latest.sources[tile]?.grid.cell(atLocalX: 3, z: 2)?.heights.x, 80)
  }
}
