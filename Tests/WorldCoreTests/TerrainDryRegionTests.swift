import Foundation
import XCTest
@testable import WorldCore

private struct DryRegionFixture: Sendable {
  let world = UUID()
  let parent: TerrainTile
  var ground = TerrainSurfaceSources()
  var water = WaterSurfaceSources()
  var waterRequests = WaterGeometryRequests()
  var visible = Set<TerrainTile>(), waterVisible = Set<TerrainTile>()
  var chunks: [ChunkCoordinate: ChunkData] = [:]
  var retainedMesh: VoxelMesh {
    var mesh = VoxelMesh()
    let width = parent.blockSize
    for z in 0..<width { for x in 0..<width {
      let a = Float(x), b = Float(z)
      mesh.appendQuad([[a,8,b],[a,8,b+1],[a+1,8,b+1],[a+1,8,b]],normal: [0,1,0],block: .stone,face: 2)
    } }
    for face in [0,1,4,5] {
      let d = VoxelMesher.offsets[face]
      let size = SIMD3<Float>(Float(width),32,Float(width)), center = SIMD3<Float>(0,-24,0)
      mesh.appendQuad(VoxelMesher.corners[face].map { center+$0*size },normal: [Float(d.x),0,Float(d.z)],block: .stone,face: face)
    }
    return mesh
  }
  init(size: Int = 1) {
    parent = .init(x: 0,z: 0,size: size)
    for z in [-size,0,size] { for x in [-size,0,size] {
      let tile = TerrainTile(x: x,z: z,size: size), side = tile.blockSize/tile.sampleStride+1
      visible.insert(tile)
      let grid = TerrainSurfaceGrid(tile: tile, heights: .init(repeating: 8,count: side*side),
        materials: .init(repeating: .stone,count: (side-1)*(side-1)))!
      ground.install(id: .init(world: world,tile: tile,revision: 0,lush: false),grid: grid)
    } }
    // Fluid coverage intentionally uses a different partition from the ground.
    for z in [-4,0] { for x in [-4,0] {
      let tile = TerrainTile(x: x,z: z,size: 4)
      waterVisible.insert(tile); waterRequests.install(.init(),tile: tile)
    } }
    publishWater()
    for z in 0..<size { for x in 0..<size {
      let key = ChunkCoordinate(x,z)
      var chunk = ChunkData(coordinate: key)
      for cz in -1...16 { for cx in -1...16 { for y in ChunkData.minimumY..<8 { chunk[cx,y,cz] = .stone } } }
      chunks[key] = chunk
    } }
  }
  mutating func publishWater() {
    for key in Array(waterRequests.dirty.keys) {
      let input = waterRequests.beginPreparation(for: key)!
      let accepted = waterRequests.publishableTiles(in: input)
      water.install(input,published: accepted)
      _ = waterRequests.acknowledge(input,published: accepted)
    }
  }
  func request(revision: UInt64 = 0) -> TerrainDryRegion.Request {
    let snapshot = ground.snapshot(visible: visible)!
    return .init(source: snapshot.sources[parent]!.id, revision: revision,
      terrain: .init(seed: 91,style: .dune), ground: snapshot,
      water: water.snapshot(visible: waterVisible)!,edits: [:])
  }
}

final class TerrainDryRegionTests: XCTestCase, @unchecked Sendable {
  private func top(_ mesh: PackedTerrainMesh, x: Float, z: Float) -> Float? {
    // Independent vertical-ray/triangle intersection against the final packed
    // product, including triangles from greedy meshing and clipped interfaces.
    var hit: Float?
    for i in stride(from: 0,to: mesh.indices.count,by: 3) {
      let v = (0..<3).map { mesh.vertices[Int(mesh.indices[i+$0])] }
      let a = SIMD3(v[0].px,v[0].py,v[0].pz), b = SIMD3(v[1].px,v[1].py,v[1].pz), c = SIMD3(v[2].px,v[2].py,v[2].pz)
      let d = (b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
      if abs(d) < 1e-6 { continue }
      let u = ((b.z-c.z)*(x-c.x)+(c.x-b.x)*(z-c.z))/d
      let v2 = ((c.z-a.z)*(x-c.x)+(a.x-c.x)*(z-c.z))/d, w = 1-u-v2
      if min(u,v2,w) >= -1e-5 { hit = max(hit ?? -.infinity,u*a.y+v2*b.y+w*c.y) }
    }
    return hit
  }
  func testCompletePackedRegionPreservesExcavationAndRaisedBlocks() throws {
    var fixture = DryRegionFixture(size: 2)
    for z in 4...10 { for x in 4...10 { for y in 3..<8 { fixture.chunks[.init(0,0)]![x,y,z] = .air } } }
    fixture.chunks[.init(1,1)]![6,8,6] = .brick
    let input = fixture.request(), result = TerrainDryRegion.assemble(input,chunks: fixture.chunks,retained: fixture.retainedMesh)
    XCTAssertEqual(result.status,.ready)
    let candidate = try XCTUnwrap(result.candidate)
    XCTAssertEqual(candidate.columnOwners.count,4)
    XCTAssertEqual(try XCTUnwrap(top(candidate.prepared.mesh,x: 7.2,z: 7.3)),3,accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(top(candidate.prepared.mesh,x: 22.2,z: 22.3)),9,accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(top(candidate.prepared.mesh,x: 18.2,z: 18.3)),8,accuracy: 0.0001)
    XCTAssertTrue(candidate.prepared.mesh.indices.allSatisfy { Int($0) < candidate.prepared.mesh.vertices.count })
    XCTAssertTrue(candidate.prepared.water.isEmpty)
    XCTAssertTrue(candidate.prepared.mesh.parts.contains { $0.material == 6 })
    XCTAssertTrue(fixture.ground.isCurrent(candidate.ground,visible: fixture.visible))
    XCTAssertTrue(fixture.water.isCurrent(candidate.water,visible: fixture.waterVisible))
    XCTAssertLessThanOrEqual(candidate.byteCount,TerrainDryRegion.maximumOutputBytes)
    let prior = PackedTerrainMesh(fixture.retainedMesh)
    func border(_ mesh: PackedTerrainMesh) -> [[Float]] {
      mesh.vertices.filter { $0.px == 0 || $0.px == 32 || $0.pz == 0 || $0.pz == 32 }.map {
        [$0.px,$0.py,$0.pz,Float($0.u),Float($0.v),Float($0.normal.x),Float($0.normal.y),Float($0.normal.z),Float($0.tangent.w)]
      }
    }
    XCTAssertEqual(border(candidate.prepared.mesh),border(prior),"Original boundary skirts and their attributes stay unchanged")
  }
  func testCutoutPreservesNonplanarTrianglesAndInterpolatedAttributes() throws {
    var source = VoxelMesh()
    source.appendQuad([[0,10,0],[0,8,4],[4,14,4],[4,11,0]],normal: [0,1,0],block: .stone,face: 2)
    source.windWeights = [0,0.25,1,0.5]
    let rectangle = TerrainMeshCutout.Rectangle(minimum: [1,1],maximum: [3,3])
    let result = try XCTUnwrap(TerrainMeshCutout.remove(rectangle,from: source))
    let original = PackedTerrainMesh(source), clipped = PackedTerrainMesh(result)
    for (x,z): (Float,Float) in [(0.3,0.6),(0.4,3.6),(3.7,0.4),(3.6,3.8),(2.1,0.4),(0.4,2.1)] {
      XCTAssertEqual(try XCTUnwrap(top(clipped,x: x,z: z)),try XCTUnwrap(top(original,x: x,z: z)),accuracy: 0.00001)
    }
    XCTAssertNil(top(clipped,x: 2.1,z: 2.2))
    for i in result.positions.indices {
      let p = result.positions[i], x = p.x/4, z = p.z/4
      let ids = z >= x ? [0,1,2] : [0,2,3]
      let weights: [Float] = z >= x ? [1-z,z-x,x] : [1-x,z,x-z]
      var uv = SIMD2<Float>.zero, wind: Float = 0
      for j in 0..<3 { uv += source.textureCoordinates[ids[j]]*weights[j]; wind += source.windWeights[ids[j]]*weights[j] }
      XCTAssertEqual(result.textureCoordinates[i].x,uv.x,accuracy: 0.00001)
      XCTAssertEqual(result.textureCoordinates[i].y,uv.y,accuracy: 0.00001)
      XCTAssertEqual(result.windWeights[i],wind,accuracy: 0.00001)
    }
    source.normals.removeLast()
    XCTAssertNil(TerrainMeshCutout.remove(rectangle,from: source))
  }
  func testOpenCaveAtBoundaryNeverPublishesAFalseWall() {
    var fixture = DryRegionFixture()
    for x in -1...8 { for y in 2...5 { fixture.chunks[.init(0,0)]![x,y,6] = .air } }
    // Open the tunnel to the sky inside the region.
    for y in 2..<8 { fixture.chunks[.init(0,0)]![8,y,6] = .air }
    let result = TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh)
    XCTAssertEqual(result.status,.exposedCave); XCTAssertNil(result.candidate)
  }
  func testEnclosedCaveCertificateExpiresWhenViewerEntersPatch() throws {
    var fixture = DryRegionFixture()
    for x in -1...5 { for y in 2...5 { fixture.chunks[.init(0,0)]![x,y,6] = .air } }
    let candidate = try XCTUnwrap(TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh).candidate)
    XCTAssertGreaterThan(candidate.enclosedCapCount,0)
    XCTAssertTrue(candidate.permits(eye: [40,10,6]))
    XCTAssertFalse(candidate.permits(eye: [2,4,6]))
    XCTAssertFalse(candidate.permits(eye: [17,4,6]),"Stereo/head-pose guard includes an exterior margin")
    XCTAssertFalse(candidate.permits(eye: [.nan,4,6]))
  }
  func testWetDisplayedCoverageAndAuthoritativeFluidBothPreventDryPublication() {
    var fixture = DryRegionFixture()
    fixture.chunks[.init(0,0)]![7,4,7] = .water
    XCTAssertEqual(TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh).status,.wet)
    fixture.chunks[.init(0,0)]![7,4,7] = .lava
    XCTAssertEqual(TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh).status,.wet)
    fixture.chunks[.init(0,0)]![7,4,7] = .stone
    var geometry = WaterGeometry()
    geometry.samples = [SIMD2<Float>(0,0),[0,4],[4,0],[4,4]].map { .init(position: $0,depth: 2,body: .ocean) }
    geometry.shallowIndices = [0,1,2,2,1,3]
    fixture.waterRequests.install(geometry,tile: .init(x: 0,z: 0,size: 4)); fixture.publishWater()
    let result = TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh)
    XCTAssertEqual(result.status,.wet); XCTAssertNil(result.candidate)
  }
  func testMissingCoverageFixturesAndCrossingStructuresRetainFallback() {
    var fixture = DryRegionFixture()
    let original = fixture.request()
    fixture.visible.remove(.init(x: -1,z: 0))
    XCTAssertEqual(TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh).status,.ready,
      "Retained border means external ground ownership is not a dependency")
    fixture.visible.insert(.init(x: -1,z: 0))
    fixture.waterVisible.remove(.init(x: -4,z: 0,size: 4))
    XCTAssertEqual(TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh).status,.missingWater)
    fixture.chunks[.init(0,0)]![2,100,4] = .brick
    XCTAssertEqual(TerrainDryRegion.assemble(original,chunks: fixture.chunks,retained: fixture.retainedMesh).status,.crossingScenery)
    fixture.chunks[.init(0,0)]![2,100,4] = .air
    fixture.chunks[.init(0,0)]![6,8,6] = .torch
    XCTAssertEqual(TerrainDryRegion.assemble(original,chunks: fixture.chunks,retained: fixture.retainedMesh).status,.unsupportedBoundary)
    XCTAssertEqual(TerrainDryRegion.assemble(original,chunks: [:],retained: fixture.retainedMesh).status,.invalidInput)
  }
  func testMixedRegionCannotAdvertiseHiddenHeightfieldAndFallbackRemainsRecoverable() throws {
    var fixture = DryRegionFixture(size: 2)
    let candidate = try XCTUnwrap(TerrainDryRegion.assemble(fixture.request(),chunks: fixture.chunks,retained: fixture.retainedMesh).candidate)
    XCTAssertNil(fixture.ground.snapshot(visible: fixture.visible,unavailable: [fixture.parent]))
    XCTAssertNil(fixture.ground.snapshot(visible: fixture.visible,unavailable: [.init(x: 0,z: 0,fullDetail: true)]))
    XCTAssertFalse(fixture.ground.isCurrent(candidate.ground,visible: fixture.visible,unavailable: [fixture.parent]))
    XCTAssertTrue(fixture.ground.isCurrent(candidate.ground,visible: fixture.visible),"Retained fallback can still validate the original dependencies")
    XCTAssertEqual(candidate.columnOwners.values.reduce(0) { $0+$1.count },28*28)
    let neighbor = TerrainTile(x: -2,z: 0,size: 2)
    let old = fixture.ground.snapshot(visible: fixture.visible)!.sources[neighbor]!
    fixture.ground.install(id: old.id,grid: old.grid)
    XCTAssertTrue(fixture.ground.isCurrent(candidate.ground,visible: fixture.visible),"The untouched border isolates external terrain changes")
    let source = fixture.ground.snapshot(visible: fixture.visible)!.sources[fixture.parent]!
    fixture.ground.install(id: source.id,grid: source.grid)
    XCTAssertFalse(fixture.ground.isCurrent(candidate.ground,visible: fixture.visible))
  }
}

@MainActor private final class DryNativeGate {
  var waiter: CheckedContinuation<Void,Never>?
  func suspend() async { await withCheckedContinuation { waiter = $0 } }
  func release() { let old = waiter; waiter = nil; old?.resume() }
}

@MainActor final class TerrainRegionTransactionTests: XCTestCase {
  private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(1)) }
    return predicate()
  }
  func testProcedurallyGeneratedEditedRegionReachesNativeReadyThroughActualWorker() async throws {
    let terrain = TerrainGenerator(seed: 1_667_327_165_707_871_140,style: .dune)
    let tile = TerrainTile(x: 40,z: 52,size: 2), world = UUID()
    XCTAssertTrue(TerrainStreamingPlan(center: .init(58,54),radius: 128,detailRadius: 16).tiles.contains(tile),
      "This procedural fixture must be reachable by the live coarse-leaf policy")
    let position = BlockPosition(648,35,840), edits: [BlockPosition:Block] = [position:.air]
    var ground = TerrainSurfaceSources(), water = WaterSurfaceSources(), requests = WaterGeometryRequests()
    var visible = Set<TerrainTile>()
    for dz in [-2,0,2] { for dx in [-2,0,2] {
      let neighbor = TerrainTile(x: tile.x+dx,z: tile.z+dz,size: 2)
      let surface = TerrainSurface.buildRetained(neighbor,terrain: terrain,edits: edits,measureError: false)
      ground.install(id: .init(world: world,tile: neighbor,revision: 1,lush: false),grid: surface.grid)
      requests.install(surface.water,tile: neighbor); visible.insert(neighbor)
    } }
    for key in Array(requests.dirty.keys) {
      let source = requests.beginPreparation(for: key)!, accepted = requests.publishableTiles(in: source)
      water.install(source,published: accepted); _ = requests.acknowledge(source,published: accepted)
    }
    let gs = try XCTUnwrap(ground.snapshot(visible: visible)), ws = try XCTUnwrap(water.snapshot(visible: visible))
    let input = TerrainDryRegion.Request(source: gs.sources[tile]!.id,revision: 1,terrain: terrain,
      ground: gs,water: ws,edits: edits)
    let worker = TerrainDryRegionWorker()
    let transaction = TerrainRegionTransaction<Int>(build: { await worker.build($0) },
      prepare: { $0.mesh.vertices.count },discard: { _ in XCTFail("Current procedural output discarded") },
      valid: { ground.isCurrent($0.ground,visible: visible) && water.isCurrent($0.water,visible: visible) })
    XCTAssertTrue(transaction.admit(input))
    let done = await eventually { !transaction.metrics.running }; XCTAssertTrue(done)
    XCTAssertTrue(transaction.metrics.ready,"Rejections: \(transaction.metrics.rejections)")
    let ready = try XCTUnwrap(transaction.takeReady())
    XCTAssertGreaterThan(ready.resource,0); XCTAssertEqual(ready.candidate.columnOwners.count,4)
    // The coarse source still capped this removed block. The accepted region
    // carries the newly exposed floor and no upward triangle at the old top.
    XCTAssertEqual(gs.sources[tile]!.grid.cell(atLocalX: 8,z: 8)?.heights.x,36)
    let vertices = ready.candidate.prepared.mesh.vertices
    XCTAssertTrue(vertices.contains { $0.py == 35 && $0.px >= 8 && $0.px <= 9 && $0.pz >= 8 && $0.pz <= 9 })
    XCTAssertEqual(transaction.metrics.completed,1)
  }
  func testNativeAwaitKeepsOneReservationAndLateWorldResultIsDiscarded() async throws {
    let fixture = DryRegionFixture(), input = fixture.request(), gate = DryNativeGate()
    let built = TerrainDryRegion.assemble(input,chunks: fixture.chunks,retained: fixture.retainedMesh)
    XCTAssertEqual(built.status,.ready)
    var discarded = 0, current = true
    let transaction = TerrainRegionTransaction<Int>(build: { _ in built },
      prepare: { _ in await gate.suspend(); return 7 },discard: { discarded += $0 },valid: { _ in current })
    XCTAssertTrue(transaction.admit(input))
    let entered = await eventually { gate.waiter != nil }; XCTAssertTrue(entered)
    XCTAssertFalse(transaction.hasCapacity); XCTAssertGreaterThan(transaction.metrics.inputBytes,0)
    let frameResponsive = await Task { @MainActor in transaction.metrics.running }.value
    XCTAssertTrue(frameResponsive)
    current = false; transaction.invalidate()
    XCTAssertTrue(transaction.metrics.running)
    XCTAssertFalse(transaction.admit(fixture.request(revision: 1)))
    gate.release()
    let done = await eventually { transaction.hasCapacity }; XCTAssertTrue(done)
    XCTAssertEqual(discarded,7); XCTAssertNil(transaction.takeReady())
    XCTAssertEqual(transaction.metrics.inputBytes,0)
  }
  func testReadyResultRevalidatesDependenciesImmediatelyBeforeSceneSwap() async throws {
    let fixture = DryRegionFixture(), input = fixture.request()
    let built = TerrainDryRegion.assemble(input,chunks: fixture.chunks,retained: fixture.retainedMesh)
    var valid = true, discarded = 0
    let transaction = TerrainRegionTransaction<Int>(build: { _ in built },prepare: { _ in 1 },
      discard: { discarded += $0 },valid: { _ in valid })
    XCTAssertTrue(transaction.admit(input))
    let ready = await eventually { transaction.metrics.ready }; XCTAssertTrue(ready)
    XCTAssertFalse(transaction.admit(input))
    valid = false
    XCTAssertNil(transaction.takeReady()); XCTAssertEqual(discarded,1)
    XCTAssertTrue(transaction.hasCapacity)
    valid = true
    XCTAssertTrue(transaction.admit(input))
    let again = await eventually { transaction.metrics.ready }; XCTAssertTrue(again)
    XCTAssertEqual(transaction.takeReady()?.resource,1)
    XCTAssertEqual(discarded,1); XCTAssertTrue(transaction.hasCapacity)
  }
  func testRejectedCPUAndFailedNativeProductsNeverBecomeSceneReady() async throws {
    enum Failure: Error { case native }
    let fixture = DryRegionFixture(), input = fixture.request()
    let rejected = TerrainRegionTransaction<Int>(build: { _ in .init(status: .wet,candidate: nil) },
      prepare: { _ in XCTFail("Rejected geometry reached native creation"); return 1 },discard: { _ in },valid: { _ in true })
    XCTAssertTrue(rejected.admit(input))
    let finished = await eventually { rejected.hasCapacity }; XCTAssertTrue(finished)
    XCTAssertEqual(rejected.metrics.rejections["wet"],1); XCTAssertNil(rejected.takeReady())
    let built = TerrainDryRegion.assemble(input,chunks: fixture.chunks,retained: fixture.retainedMesh)
    let failed = TerrainRegionTransaction<Int>(build: { _ in built },prepare: { _ in throw Failure.native },
      discard: { _ in XCTFail("Failed creation has no resource") },valid: { _ in true })
    XCTAssertTrue(failed.admit(input))
    let done = await eventually { failed.hasCapacity }; XCTAssertTrue(done)
    XCTAssertEqual(failed.metrics.failed,1); XCTAssertNil(failed.takeReady())
  }
}
