import XCTest

@testable import WorldCore

final class CreativeWorldTests: XCTestCase {
  func testCreativeFlightDescendsOntoGroundAndReturnsToWalking() {
    var player = PlayerPhysics(position: [0.5, 6, 0.5])
    player.flying = true
    for _ in 0..<90 {
      player.update(deltaTime: 1 / 90, movement: [0, -1, 0], jump: false, sprint: false) {
        $0.y == 0 ? .stone : .air
      }
    }
    XCTAssertFalse(player.flying)
    XCTAssertTrue(player.grounded)
    XCTAssertEqual(player.position.y, 1, accuracy: 0.04)
  }

  func testFlyingUpIsBlockedByCeilingWithoutCancellingFlight() {
    var player = PlayerPhysics(position: [0.5, 1, 0.5])
    player.flying = true
    for _ in 0..<90 {
      player.update(deltaTime: 1 / 90, movement: [0, 1, 0], jump: false, sprint: true) {
        $0.y == 5 ? .stone : .air
      }
    }
    XCTAssertLessThanOrEqual(player.position.y + PlayerPhysics.height, 5.001)
    XCTAssertTrue(player.flying)
  }

  func testDrawDistanceExpandsHorizonWhileBoundingFullDetail() {
    let near = ChunkStreamingPlan(center: .init(0, 0), radius: 4)
    let far = ChunkStreamingPlan(center: .init(0, 0), radius: 32)
    XCTAssertGreaterThan(far.chunks.count, near.chunks.count * 50)
    XCTAssertEqual(far.chunks[.init(32, 0)], .distant)
    XCTAssertNil(far.chunks[.init(33, 0)])
    XCTAssertEqual(far.chunks[.init(0, 0)], .full)
    XCTAssertLessThanOrEqual(far.chunks.values.filter { $0 == .full }.count, 317)
    XCTAssertEqual(far.chunks[.init(12, 0)], .reduced)
  }

  func testDrawDistanceClampsAndPlanUpdatesAsPlayerMoves() {
    XCTAssertEqual(DrawDistance.clamp(-1), 4)
    XCTAssertEqual(DrawDistance.clamp(1_000), 128)
    let plan = ChunkStreamingPlan(center: .init(-20, 7), radius: 16)
    XCTAssertEqual(plan.chunks[.init(-20, 7)], .full)
    XCTAssertEqual(plan.chunks[.init(-4, 7)], .distant)
    XCTAssertNil(plan.chunks[.init(0, 0)])
  }

  func testDistantMeshIsBoundedAndSharesBoundarySamplesAcrossDetailLevels() {
    let terrain = TerrainGenerator(seed: 8192)
    let a = TerrainLOD.build(terrain.generate(.init(0, 0), includeCaves: false), sampleStride: 2)
    let b = TerrainLOD.build(terrain.generate(.init(1, 0), includeCaves: false), sampleStride: 4)
    XCTAssertLessThanOrEqual(a.faceCount, 96)
    XCTAssertLessThanOrEqual(b.faceCount, 32)
    let edgeA = a.positions.prefix(64 * 4).filter { $0.x == 16 }
    let edgeB = b.positions.prefix(16 * 4).filter { $0.x == 0 }
    for p in edgeB { XCTAssertTrue(edgeA.contains { $0.z == p.z && $0.y == p.y }) }
    for mesh in [a, b] {
      XCTAssertEqual(mesh.materials.count, mesh.indices.count / 3)
      for i in stride(from: 0, to: mesh.indices.count, by: 3) {
        let p = mesh.positions[Int(mesh.indices[i])]
        let q = mesh.positions[Int(mesh.indices[i + 1])] - p
        let r = mesh.positions[Int(mesh.indices[i + 2])] - p
        let cross = SIMD3(q.y * r.z - q.z * r.y, q.z * r.x - q.x * r.z, q.x * r.y - q.y * r.x)
        let n = mesh.normals[Int(mesh.indices[i])]
        XCTAssertGreaterThan(cross.x * n.x + cross.y * n.y + cross.z * n.z, 0)
      }
    }
  }

  func testCoarseWaterRetainsWorldSpaceSamplesAndCutsVertexCount() {
    var chunk = ChunkData(coordinate: .init(-2, 3))
    for x in -1...16 { for z in -1...16 { chunk[x, 2, z] = .sand } }
    let full = WaterPatch.build(chunk)
    let coarse = WaterPatch.build(chunk, sampleStride: 4)
    XCTAssertEqual(coarse.vertexSide, 5)
    XCTAssertEqual(coarse.depths.count, 25)
    XCTAssertEqual(coarse.deepIndices.count, 16 * 6)
    for z in 0..<5 {
      for x in 0..<5 {
        XCTAssertEqual(coarse.depths[z * 5 + x], full.depths[z * 4 * 17 + x * 4])
      }
    }
  }

  func testCavesAreSeededAndProtectBedrockAndWaterCeilings() {
    let caves = CaveGenerator(seed: 8192)
    let other = CaveGenerator(seed: 17)
    var open = 0
    var different = 0
    for x in stride(from: -60, through: 60, by: 3) {
      for y in stride(from: -55, through: 20, by: 3) {
        let p = BlockPosition(x, y, x / 2)
        let carved = caves.isCarved(at: p, surface: 35, waterCovered: false)
        XCTAssertEqual(carved, caves.isCarved(at: p, surface: 35, waterCovered: false))
        if carved { open += 1 }
        if carved != other.isCarved(at: p, surface: 35, waterCovered: false) { different += 1 }
      }
      for y in ChunkData.minimumY...(ChunkData.minimumY + 3) {
        XCTAssertFalse(caves.isCarved(at: .init(x, y, 0), surface: 35, waterCovered: false))
      }
      for y in 31...35 {
        XCTAssertFalse(caves.isCarved(at: .init(x, y, 0), surface: 35, waterCovered: true))
      }
    }
    XCTAssertGreaterThan(open, 20)
    XCTAssertGreaterThan(different, 20)
  }

  func testGeneratedCavesAgreeWithFallbackAndContinueAcrossChunkSeams() {
    let terrain = TerrainGenerator(seed: 8192)
    let a = terrain.generate(.init(6, -3))
    let b = terrain.generate(.init(7, -3))
    var undergroundAir = 0
    for y in (ChunkData.minimumY + 4)..<20 {
      for z in 0..<16 {
        XCTAssertEqual(a[16, y, z], b[0, y, z])
        XCTAssertEqual(a[15, y, z], b[-1, y, z])
        let p = BlockPosition(6 * 16 + 8, y, -3 * 16 + z)
        XCTAssertEqual(a[8, y, z], terrain.block(at: p))
        if y < terrain.height(atX: p.x, z: p.z) - 5 && a[8, y, z] == .air { undergroundAir += 1 }
      }
    }
    XCTAssertGreaterThan(undergroundAir, 10)
    let edited = terrain.generate(.init(6, -3), edits: [.init(104, -20, -40): .glass])
    XCTAssertEqual(edited[8, -20, 8], .glass)
  }

  func testCaveTunnelsHaveNaturalSurfaceEntrances() {
    let terrain = TerrainGenerator(seed: 8192)
    let caves = CaveGenerator(seed: 8192)
    var entrances = 0
    for x in stride(from: -800, through: 800, by: 8) {
      for z in stride(from: -800, through: 800, by: 8) {
        let h = terrain.height(atX: x, z: z)
        if caves.isCarved(
          at: .init(x, h, z), surface: h, waterCovered: terrain.waterBody(atX: x, z: z) != nil)
        {
          entrances += 1
        }
      }
    }
    XCTAssertGreaterThan(entrances, 10)
  }

  func testSunAndMoonRiseSetAndRepeatWithTheWorldClock() {
    let midnight = WorldEnvironment(elapsed: 0)
    let sunrise = WorldEnvironment(elapsed: 300)
    let noon = WorldEnvironment(elapsed: 600)
    let sunset = WorldEnvironment(elapsed: 900)
    XCTAssertEqual(midnight.sunVisibility, 0)
    XCTAssertEqual(midnight.moonVisibility, 1)
    XCTAssertEqual(noon.sunVisibility, 1)
    XCTAssertEqual(noon.moonVisibility, 0)
    XCTAssertEqual(sunrise.sunDirection.y, 0, accuracy: 0.00001)
    XCTAssertEqual(sunset.sunDirection.y, 0, accuracy: 0.00001)
    XCTAssertEqual(sunrise.sunDirection.x, -sunset.sunDirection.x, accuracy: 0.00001)
    for time in stride(from: 0, through: 1_200, by: 75) {
      let e = WorldEnvironment(elapsed: Double(time))
      XCTAssertEqual(e.moonDirection, -e.sunDirection)
      let later = WorldEnvironment(elapsed: Double(time + 1_200))
      for axis in 0..<3 {
        XCTAssertEqual(e.sunDirection[axis], later.sunDirection[axis], accuracy: 0.00001)
      }
    }
  }
}
