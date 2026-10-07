import XCTest

@testable import WorldCore

final class WorldCoreTests: XCTestCase {
  func testNegativeCoordinatesUseFloorDivision() {
    XCTAssertEqual(BlockPosition(-1, 0, -17).chunk, ChunkCoordinate(-1, -2))
    XCTAssertEqual(BlockPosition(-16, 0, -16).chunk, ChunkCoordinate(-1, -1))
    XCTAssertEqual(BlockPosition(16, 0, 0).chunk, ChunkCoordinate(1, 0))
  }

  func testTerrainIsDeterministicAndSeedChangesLandscape() {
    let a = TerrainGenerator(seed: 8192)
    let b = TerrainGenerator(seed: 8192)
    let c = TerrainGenerator(seed: 24)
    let points = (-20...20).map { a.height(atX: $0 * 5, z: $0 * 3) }
    XCTAssertEqual(points, (-20...20).map { b.height(atX: $0 * 5, z: $0 * 3) })
    XCTAssertNotEqual(points, (-20...20).map { c.height(atX: $0 * 5, z: $0 * 3) })
  }

  func testChunkBordersAgreeIncludingTreesAndEdits() {
    let generator = TerrainGenerator(seed: 8192)
    let edits: [BlockPosition: Block] = [.init(-1, 22, 3): .brick, .init(0, 23, 3): .air]
    let a = generator.generate(.init(-1, 0), edits: edits)
    let b = generator.generate(.init(0, 0), edits: edits)
    for y in 0..<ChunkData.height {
      for z in 0..<16 {
        XCTAssertEqual(a[16, y, z], b[0, y, z], "Seam mismatch at \(y),\(z)")
        XCTAssertEqual(a[15, y, z], b[-1, y, z], "Border mismatch at \(y),\(z)")
      }
    }
    XCTAssertEqual(a[15, 22, 3], .brick)
    XCTAssertEqual(b[-1, 22, 3], .brick)
  }

  func testFallbackSamplerAgreesWithGeneratedChunk() {
    for seed: UInt64 in [8192, 0, 17, 492, 99_999] {
      let generator = TerrainGenerator(seed: seed)
      let chunk = generator.generate(.init(0, 0))
      for x in 0..<16 {
        for z in 0..<16 {
          for y in 14..<40 {
            XCTAssertEqual(
              chunk[x, y, z], generator.block(at: .init(x, y, z)),
              "Mismatch at \(x),\(y),\(z), seed \(seed)")
          }
        }
      }
    }
  }

  func testSpawnHasGroundAndHeadroom() {
    for seed: UInt64 in [0, 1, 8192, 999_999, UInt64.max] {
      let generator = TerrainGenerator(seed: seed)
      let point = generator.spawn()
      let feet = BlockPosition(point)
      XCTAssertEqual(generator.block(at: feet), .air)
      XCTAssertEqual(generator.block(at: feet + .init(0, 1, 0)), .air)
      XCTAssertTrue(generator.block(at: feet + .init(0, -1, 0)).isSolid)
    }
  }

  func testMesherCullsInteriorFacesAndWindsOutward() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[3, 3, 3] = .stone
    chunk[4, 3, 3] = .stone
    let mesh = VoxelMesher.build(chunk)
    XCTAssertEqual(mesh.faceCount, 10)
    XCTAssertEqual(mesh.materials.count, mesh.indices.count / 3)
    for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
      let a = mesh.positions[Int(mesh.indices[triangle])]
      let b = mesh.positions[Int(mesh.indices[triangle + 1])] - a
      let c = mesh.positions[Int(mesh.indices[triangle + 2])] - a
      let cross = SIMD3(b.y * c.z - b.z * c.y, b.z * c.x - b.x * c.z, b.x * c.y - b.y * c.x)
      let normal = mesh.normals[Int(mesh.indices[triangle])]
      XCTAssertGreaterThan(cross.x * normal.x + cross.y * normal.y + cross.z * normal.z, 0)
    }
    XCTAssertTrue(
      mesh.textureCoordinates.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
  }

  func testSeamNeighborSuppressesHiddenFace() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[15, 3, 3] = .stone
    chunk[16, 3, 3] = .stone
    XCTAssertEqual(VoxelMesher.build(chunk).faceCount, 5)
  }

  func testTransparentWaterAndGlassHaveSeparateMaterials() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[3, 3, 3] = .water
    chunk[8, 3, 3] = .glass
    let mesh = VoxelMesher.build(chunk)
    XCTAssertEqual(mesh.faceCount, 12)
    XCTAssertEqual(Set(mesh.materials), [1, 2])
  }

  func testRaycastReturnsAdjacentCellAcrossNegativeCoordinates() {
    let hit = VoxelRaycast.cast(origin: [0.5, 2.5, 0.5], direction: [-1, 0, 0]) { p in
      p == .init(-3, 2, 0) ? .stone : .air
    }
    XCTAssertEqual(hit?.block, .init(-3, 2, 0))
    XCTAssertEqual(hit?.adjacent, .init(-2, 2, 0))
    XCTAssertEqual(hit?.distance ?? 0, 2.5, accuracy: 0.001)
    XCTAssertNil(VoxelRaycast.cast(origin: [0, 0, 0], direction: .zero) { _ in .stone })
  }

  func testRaycastSkipsWaterAndRespectsReach() {
    let hit = VoxelRaycast.cast(origin: [0.5, 2.5, 0.5], direction: [0, 0, -1], reach: 6) { p in
      p.z == -2 ? .water : (p.z == -4 ? .stone : .air)
    }
    XCTAssertEqual(hit?.block, .init(0, 2, -4))
    XCTAssertNil(
      VoxelRaycast.cast(origin: [0.5, 2.5, 0.5], direction: [0, 0, -1], reach: 2) { p in
        p.z == -4 ? .stone : .air
      })
  }

  func testPhysicsLandsJumpsAndCannotWalkThroughWall() {
    func block(_ p: BlockPosition) -> Block { p.y == 0 || p.x == 3 ? .stone : .air }
    var player = PlayerPhysics(position: [1.5, 4, 1.5])
    for _ in 0..<180 {
      player.update(deltaTime: 1 / 90, movement: .zero, jump: false, sprint: false, block: block)
    }
    XCTAssertTrue(player.grounded)
    XCTAssertEqual(player.position.y, 1, accuracy: 0.035)
    player.update(deltaTime: 1 / 90, movement: .zero, jump: true, sprint: false, block: block)
    XCTAssertGreaterThan(player.verticalVelocity, 0)
    for _ in 0..<180 {
      player.update(
        deltaTime: 1 / 90, movement: [1, 0, 0], jump: false, sprint: true, block: block)
    }
    XCTAssertLessThanOrEqual(player.position.x + PlayerPhysics.radius, 3)
  }

  func testPlacementCannotOverlapPlayerBody() {
    let player = PlayerPhysics(position: [0.5, 5.3, 0.5])
    XCTAssertTrue(player.overlaps(.init(0, 5, 0)))
    XCTAssertTrue(player.overlaps(.init(1, 5, 0)))
    XCTAssertFalse(player.overlaps(.init(2, 5, 0)))
  }

  func testPlayerFrameRoundTripsWorldAndHeadsetPositions() {
    let frame = PlayerFrame(
      referenceEye: [0.3, 1.15, -0.8], feet: [71, 22, -108], heading: .pi / 3)
    let point = SIMD3<Float>(81, 25, -117)
    let roundTrip = frame.worldPoint(fromTracked: frame.trackedPoint(fromWorld: point))
    for axis in 0..<3 { XCTAssertEqual(roundTrip[axis], point[axis], accuracy: 0.0001) }
    XCTAssertEqual(frame.worldPoint(fromTracked: frame.referenceEye), frame.eye)
    XCTAssertEqual(frame.trackedPoint(fromWorld: .zero), frame.worldOriginInTracking)
  }

  func testHeadParallaxAndPitchRemainIndependentOfLocomotion() {
    let frame = PlayerFrame(referenceEye: [0, 1.2, 0], feet: [4, 18, 9], heading: .pi / 2)
    let leaning = frame.worldPoint(fromTracked: [0.2, 1.2, 0]) - frame.eye
    XCTAssertEqual(leaning.x, 0, accuracy: 0.0001)
    XCTAssertEqual(WorldScale.metres(leaning.z), -0.2, accuracy: 0.0001)
    let tiltedLook = frame.worldDirection(fromTracked: [0, -0.6, -0.8])
    XCTAssertEqual(tiltedLook.x, -0.8, accuracy: 0.0001)
    XCTAssertEqual(tiltedLook.y, -0.6, accuracy: 0.0001)
    XCTAssertEqual(frame.feet, [4, 18, 9])
  }
}
