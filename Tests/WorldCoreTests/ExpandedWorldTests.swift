import XCTest

@testable import WorldCore

final class ExpandedWorldTests: XCTestCase {
  func testRadialDeadzonePreservesAnalogSpeedAndDirection() {
    XCTAssertEqual(LocomotionInput.movement([0.08, 0.08]), .zero)
    let slow = LocomotionInput.movement([0.3, 0.4])
    XCTAssertEqual(slow.x / slow.y, 0.75, accuracy: 0.0001)
    XCTAssertLessThan(sqrt(slow.x * slow.x + slow.y * slow.y), 0.5)
    let full = LocomotionInput.movement([1, 1])
    XCTAssertEqual(sqrt(full.x * full.x + full.y * full.y), 1, accuracy: 0.0001)
    XCTAssertLessThan(LocomotionInput.axis(0.4), LocomotionInput.axis(0.8))
    XCTAssertEqual(LocomotionInput.axis(-1), -1)
  }

  func testBodyHeadingDefinesWalkingAndStrafing() {
    XCTAssertEqual(LocomotionInput.worldMovement([0, 1], heading: 0), [0, 0, -1])
    let rightTurn = LocomotionInput.worldMovement([0, 1], heading: -.pi / 2)
    XCTAssertEqual(rightTurn.x, 1, accuracy: 0.0001)
    XCTAssertEqual(rightTurn.z, 0, accuracy: 0.0001)
    let strafe = LocomotionInput.worldMovement([1, 0], heading: -.pi / 2)
    XCTAssertEqual(strafe.z, 1, accuracy: 0.0001)
  }

  func testDoubleJumpRequiresTwoDistinctPressesWithinWindow() {
    var gesture = DoubleJumpGesture()
    XCTAssertFalse(gesture.press(at: 1))
    XCTAssertTrue(gesture.press(at: 1.2))
    XCTAssertFalse(gesture.press(at: 1.25), "A third press starts a new pair")
    gesture.reset()
    XCTAssertFalse(gesture.press(at: 2))
    XCTAssertFalse(gesture.press(at: 2.5))
    XCTAssertTrue(gesture.press(at: 2.7))
  }

  func testDayNightAndTidesRepeatOnTheirPeriods() {
    var night = WorldEnvironment(elapsed: 0)
    let noon = WorldEnvironment(elapsed: 600)
    XCTAssertLessThan(night.daylight, 0.01)
    XCTAssertGreaterThan(noon.daylight, 0.99)
    XCTAssertLessThan(night.sunDirection.y, 0)
    XCTAssertGreaterThan(noon.sunDirection.y, 0)
    XCTAssertEqual(night.tide, noon.tide, accuracy: 0.00001)
    let before = night.elapsed
    night.advance(0)
    XCTAssertEqual(night.elapsed, before)
    night.advance(1_200)
    XCTAssertEqual(night.dayFraction, 0)
    XCTAssertEqual(noon.clock, "12:00")
    XCTAssertGreaterThan(WorldEnvironment(elapsed: 300).twilight, 0.5)
  }

  func testWavesAnimateHaveBoundedHeightAndAnalyticNormals() {
    let a = WorldEnvironment(elapsed: 10)
    let b = WorldEnvironment(elapsed: 11)
    let wave = a.water(atX: 7, z: -13)
    XCTAssertNotEqual(wave.height, b.water(atX: 7, z: -13).height)
    XCTAssertLessThan(abs(wave.height - WorldEnvironment.meanWaterLevel), 1.1)
    let n = wave.normal
    XCTAssertEqual(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1, accuracy: 0.0001)
    let dx = (a.water(atX: 7.01, z: -13).height - a.water(atX: 6.99, z: -13).height) / 0.02
    XCTAssertEqual(-n.x / n.y, dx, accuracy: 0.0002)
    XCTAssertLessThan(
      abs(a.water(atX: 7, z: -13, depth: 0.2).height - a.waterLevel),
      abs(wave.height - a.waterLevel))
  }

  func testDeepOceanExistsAndContainsWaterToTheSurface() {
    let generator = TerrainGenerator(seed: 8192)
    var ocean: BlockPosition?
    search: for x in stride(from: -8_000, through: 8_000, by: 80) {
      for z in stride(from: -8_000, through: 8_000, by: 80) {
        let h = generator.height(atX: x, z: z)
        if TerrainGenerator.seaLevel - h >= 60 {
          ocean = .init(x, h + 1, z)
          break search
        }
      }
    }
    guard let ocean else { return XCTFail("Seed must contain deep ocean basins") }
    XCTAssertEqual(generator.block(at: ocean), .water)
    XCTAssertEqual(generator.block(at: .init(ocean.x, TerrainGenerator.seaLevel, ocean.z)), .water)
    XCTAssertTrue(generator.block(at: ocean + .init(0, -1, 0)).isSolid)
    let chunk = generator.generate(ocean.chunk)
    let x = ocean.x - ocean.chunk.x * 16
    let z = ocean.z - ocean.chunk.z * 16
    XCTAssertEqual(chunk[x, ocean.y, z], .water)
    XCTAssertTrue(chunk[x, ocean.y - 1, z].isSolid)
    let patch = WaterPatch.build(chunk, terrain: generator)
    XCTAssertEqual(patch.depths[z * 17 + x], Float(TerrainGenerator.seaLevel - ocean.y + 1))
    XCTAssertFalse(VoxelMesher.build(chunk, includeWater: false).positions.isEmpty)
  }

  func testSwimmingCanDiveFarBelowTheSurface() {
    var player = PlayerPhysics(position: [0.5, 8, 0.5])
    for _ in 0..<900 {
      player.update(
        deltaTime: 1 / 90, movement: [0, -1, 0], jump: false, sprint: false, waterLevel: 10
      ) { _ in .water }
    }
    XCTAssertLessThan(player.position.y, -10)
  }

  func testCreativeFlightCanRiseThroughCloudsAndReachSpace() {
    var player = PlayerPhysics(position: [0, 40, 0])
    player.flying = true
    for _ in 0..<18_000 {
      player.update(deltaTime: 1 / 90, movement: [0, 1, 0], jump: false, sprint: false) { _ in .air
      }
    }
    XCTAssertGreaterThan(player.position.y, SolarSystem.departureAltitude)
  }

  func testWaterPatchWindingAndSharedDepthsAgreeAcrossSeams() {
    var a = ChunkData(coordinate: .init(0, 0))
    var b = ChunkData(coordinate: .init(1, 0))
    for x in -1...16 {
      for z in -1...16 {
        a[x, 3, z] = .sand
        b[x, 3, z] = .sand
      }
    }
    let first = WaterPatch.build(a)
    let second = WaterPatch.build(b)
    XCTAssertEqual(first.deepIndices.count, 16 * 16 * 6)
    for z in 0..<17 { XCTAssertEqual(first.depths[z * 17 + 16], second.depths[z * 17]) }
    let indices = first.deepIndices
    for i in stride(from: 0, to: indices.count, by: 3) {
      func point(_ index: UInt32) -> SIMD3<Float> { [Float(index % 17), 0, Float(index / 17)] }
      let p = point(indices[i])
      let q = point(indices[i + 1]) - p
      let r = point(indices[i + 2]) - p
      XCTAssertGreaterThan(q.z * r.x - q.x * r.z, 0, "Water triangles must face upward")
    }
    a[2, TerrainGenerator.seaLevel + 2, 2] = .stone
    XCTAssertLessThan(WaterPatch.build(a).deepIndices.count, first.deepIndices.count)
  }

  func testVoxelWaterCanBeExcludedWithoutRemovingSolidBoundaries() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[2, 2, 2] = .stone
    chunk[3, 2, 2] = .water
    let mesh = VoxelMesher.build(chunk, includeWater: false)
    XCTAssertEqual(mesh.faceCount, 6)
    XCTAssertEqual(Set(mesh.materials), [0])
  }

  func testSwimmingProvidesBuoyancyAndRetainsWallCollisions() {
    var player = PlayerPhysics(position: [0.5, 3, 0.5])
    for _ in 0..<900 {
      player.update(deltaTime: 1 / 90, movement: .zero, jump: false, sprint: false, waterLevel: 10)
      { $0.y == 0 ? .sand : .water }
    }
    XCTAssertEqual(player.position.y + PlayerPhysics.height * 0.65, 10, accuracy: 0.15)
  }

  func testCreativeFlightHoversAndStopsImmediatelyAfterInputEnds() {
    var player = PlayerPhysics(position: [0, 100, 0])
    player.flying = true
    player.verticalVelocity = -20
    for _ in 0..<90 {
      player.update(deltaTime: 1 / 90, movement: .zero, jump: false, sprint: false) { _ in .air }
    }
    XCTAssertEqual(player.position, [0, 100, 0])
    XCTAssertEqual(player.verticalVelocity, 0)
    player.update(deltaTime: 0.05, movement: [0, 0, -1], jump: false, sprint: false) { _ in .air }
    XCTAssertLessThan(player.position.z, 0)
    let stopped = player.position
    player.update(deltaTime: 0.05, movement: .zero, jump: false, sprint: false) { _ in .air }
    XCTAssertEqual(player.position, stopped)
    XCTAssertEqual(player.velocity, .zero)
  }

  func testCreativeFlightSupportsAnalogStrafingAndSprintWithoutGravity() {
    var slow = PlayerPhysics(position: [0, 100, 0])
    var fast = slow
    slow.flying = true
    fast.flying = true
    slow.update(deltaTime: 0.05, movement: [0.5, 0, 0], jump: false, sprint: false) { _ in .air }
    fast.update(deltaTime: 0.05, movement: [1, 0, 0], jump: false, sprint: true) { _ in .air }
    XCTAssertEqual(fast.position.x, slow.position.x * 4, accuracy: 0.001)
    XCTAssertEqual(slow.position.y, 100)
    XCTAssertEqual(fast.position.y, 100)
  }

  func testFastFlightCannotTunnelThroughWall() {
    var player = PlayerPhysics(position: [0.5, 10, 0.5])
    player.flying = true
    for _ in 0..<30 {
      player.update(deltaTime: 0.05, movement: [1, 0, 0], jump: false, sprint: true) {
        $0.x == 3 ? .stone : .air
      }
    }
    XCTAssertGreaterThan(player.position.x, 2)
    XCTAssertLessThanOrEqual(player.position.x + PlayerPhysics.radius, 3)
    XCTAssertTrue(player.flying, "A wall must not cancel hover flight")
  }

  func testWildlifeSpawnIsSeededAndMatchesLandOrWaterHabitat() {
    let generator = TerrainGenerator(seed: 8192)
    var count = 0
    for x in -8...8 {
      for z in -8...8 {
        let chunk = ChunkCoordinate(x, z)
        let first = AnimalState.spawn(in: chunk, generator: generator, block: generator.block)
        let second = AnimalState.spawn(in: chunk, generator: generator, block: generator.block)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(first?.position, second?.position)
        if let first {
          count += 1
          if first.kind.aquatic {
            XCTAssertEqual(generator.block(at: BlockPosition(first.position)), .water)
          } else {
            XCTAssertTrue(generator.block(at: BlockPosition(first.position) + .init(0, -1, 0)).isSolid)
            XCTAssertEqual(generator.block(at: BlockPosition(first.position)), .air)
          }
          let cell = BlockPosition(first.position)
          XCTAssertTrue(generator.biome(atX: cell.x, z: cell.z).animals.contains(first.kind))
        }
      }
    }
    XCTAssertGreaterThan(count, 3)
  }
}
