import XCTest

@testable import WorldCore

final class SolarTravelTests: XCTestCase {
  func testPlanetsOrbitOneStationarySunAndFollowKeplerPeriods() throws {
    let system = SolarSystem(seed: 8192)
    XCTAssertEqual(system.sun.name, "Sun")
    XCTAssertTrue(system.sun.isStar)
    XCTAssertNil(system.sun.orbit)
    XCTAssertEqual(system.sun.position(at: 30_000), system.sun.center)
    var constant: Double?
    for planet in system.planets where !planet.isStar {
      let orbit = try XCTUnwrap(planet.orbit)
      XCTAssertEqual(orbit.focus, system.sun.center)
      let ratio = orbit.period * orbit.period / pow(Double(orbit.radius), 3)
      if let constant { XCTAssertEqual(ratio, constant, accuracy: 0.000000001) } else { constant = ratio }
      for phase in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let relative = planet.position(at: orbit.period * phase) - system.sun.center
        XCTAssertEqual(length(relative), orbit.radius, accuracy: 0.002)
      }
      let opposite = planet.position(at: orbit.period / 2) - system.sun.center
      let initial = planet.center - system.sun.center
      XCTAssertLessThan(length(opposite + initial), 0.003)
      XCTAssertLessThan(length(planet.position(at: orbit.period) - planet.center), 0.003)
    }
    let ordered = system.planets.filter { !$0.isStar }.sorted { $0.orbit!.radius < $1.orbit!.radius }
    for i in 1..<ordered.count {
      XCTAssertGreaterThan(ordered[i].orbit!.period, ordered[i - 1].orbit!.period)
      XCTAssertGreaterThan(ordered[i].orbit!.radius - ordered[i - 1].orbit!.radius, ordered[i].radius + ordered[i - 1].radius)
    }
  }

  func testDepartureAndLandingUseCurrentOrbitPositionsIncludingSun() {
    let system = SolarSystem(seed: 8192)
    let time = 775.0
    let origin = system.planets[0]
    var flight = SpaceFlight(departing: origin, heading: 0.3, time: time)
    XCTAssertEqual(flight.position, origin.position(at: time) + [0, origin.radius + 55, 0])
    XCTAssertNil(flight.update(deltaTime: 0, movement: .zero, system: system, time: time))
    let destination = system.planets[2]
    flight.position = destination.position(at: time) + [0, destination.radius + 19, 0]
    XCTAssertEqual(flight.distance(to: destination, time: time), 19, accuracy: 0.002)
    XCTAssertEqual(flight.update(deltaTime: 0, movement: .zero, system: system, time: time), destination.index)
    flight.position = system.sun.center + [0, system.sun.radius + 19, 0]
    XCTAssertEqual(flight.update(deltaTime: 0, movement: .zero, system: system, time: time), SolarSystem.sunIndex)
    var fromSun = SpaceFlight(departing: system.sun, heading: 0, time: time)
    XCTAssertNil(fromSun.update(deltaTime: 0, movement: .zero, system: system, time: time))
  }

  func testSolarTerrainHasMoltenBasinsAndDryBasaltSpawn() throws {
    let terrain = SolarSystem(seed: 8192).sun.terrain
    XCTAssertEqual(terrain.style, .solar)
    var found: BlockPosition?
    search: for x in stride(from: -4096, through: 4096, by: 64) {
      for z in stride(from: -4096, through: 4096, by: 64) {
        // Landmark pads intentionally replace natural basins with dry ground.
        if !terrain.landmarks.contains(where: { $0.contains(x:x,z:z) }),
          terrain.height(atX: x, z: z) < TerrainGenerator.seaLevel - 4 {
          found = .init(x, TerrainGenerator.seaLevel, z); break search
        }
      }
    }
    let p = try XCTUnwrap(found)
    XCTAssertEqual(terrain.block(at: p), .lava)
    XCTAssertEqual(terrain.waterBody(atX: p.x, z: p.z)?.kind, .lava)
    XCTAssertNil(terrain.lake(nearX: p.x, z: p.z))
    XCTAssertNil(terrain.tree(atX: p.x, z: p.z))
    XCTAssertEqual(SettlementGenerator.site(in: .init(0, 0), terrain: terrain)?.habitat, .solar)
    let chunk = terrain.generate(p.chunk)
    let x = p.x - p.chunk.x * 16, z = p.z - p.chunk.z * 16
    XCTAssertEqual(chunk[x, p.y, z], .lava)
    let surface = WaterPatch.build(chunk, terrain: terrain)
    XCTAssertFalse(surface.isEmpty)
    XCTAssertEqual(surface.bodies[z * 17 + x].kind, .lava)
    let spawn = BlockPosition(terrain.spawn())
    XCTAssertEqual(terrain.block(at: spawn), .air)
    XCTAssertEqual(terrain.block(at: spawn + .init(0, -1, 0)), .basalt)
    XCTAssertGreaterThan(spawn.y, TerrainGenerator.seaLevel)
  }

  func testLavaIsAnAnimatedOpaqueFluidWithProtectedSolidBoundaries() {
    XCTAssertFalse(Block.lava.isSolid)
    XCTAssertTrue(Block.lava.isLiquid)
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[1, 10, 1] = .stone
    chunk[2, 10, 1] = .lava
    XCTAssertEqual(VoxelMesher.build(chunk, includeWater: false).faceCount, 6)
    XCTAssertTrue(VoxelMesher.build(chunk).materials.contains(5))
    let a = WorldEnvironment(elapsed: 40).water(atX: 7, z: 12, body: .lava)
    let b = WorldEnvironment(elapsed: 42).water(atX: 7, z: 12, body: .lava)
    XCTAssertNotEqual(a.height, b.height)
    XCTAssertLessThan(abs(a.height - WaterBody.lava.level), 0.28)
    XCTAssertLessThan(abs(b.height - WaterBody.lava.level), 0.28)
    XCTAssertEqual(length(a.normal), 1, accuracy: 0.00001)
  }

  func testSolarClockLookPitchAndSunVisitsRoundTripAndValidate() throws {
    var save = WorldSave(seed: 8192, edits: [], player: [1, 50, 1], flying: true,
      heading: 0.5, selectedSlot: 0, planetIndex: SolarSystem.sunIndex,
      systemTime: 775, viewPitch: 0.6)
    save.visitedPlanets = [.init(index: SolarSystem.sunIndex, edits: [], player: [1, 50, 1], heading: 0.5, worldTime: 400)]
    XCTAssertTrue(save.isValid)
    let restored = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    XCTAssertTrue(restored.isValid)
    XCTAssertEqual(restored.systemTime, 775)
    XCTAssertEqual(restored.viewPitch, 0.6)
    XCTAssertEqual(restored.planetIndex, SolarSystem.sunIndex)
    save.systemTime = -.infinity
    XCTAssertFalse(save.isValid)
    save.systemTime = 1
    save.viewPitch = .nan
    XCTAssertFalse(save.isValid)
    save.viewPitch = 2
    XCTAssertFalse(save.isValid)
  }

  func testAnalogLookPitchHasDeadzoneSignedRatesAndLimits() {
    XCTAssertEqual(LocomotionInput.lookPitchDelta(axis: 0.1, speed: 90, deltaTime: 0.02), 0)
    let gentle = LocomotionInput.lookPitchDelta(axis: 0.4, speed: 90, deltaTime: 0.02)
    let full = LocomotionInput.lookPitchDelta(axis: 1, speed: 90, deltaTime: 0.02)
    XCTAssertGreaterThan(gentle, 0)
    XCTAssertLessThan(gentle, full)
    XCTAssertEqual(LocomotionInput.lookPitchDelta(axis: -1, speed: 90, deltaTime: 0.02), -full)
    XCTAssertEqual(LocomotionInput.clampLookPitch(100), LocomotionInput.maximumLookPitch)
    XCTAssertEqual(LocomotionInput.clampLookPitch(-100), -LocomotionInput.maximumLookPitch)
  }

  func testBodyPitchPreservesHeadParallaxAndInverseTransforms() {
    let frame = PlayerFrame(referenceEye: [0.2, 1.6, -0.3], feet: [120, 32, -180], heading: 0.8, pitch: 0.6)
    XCTAssertEqual(frame.worldPoint(fromTracked: frame.referenceEye), frame.eye)
    let direction = frame.worldDirection(fromTracked: [0, 0, -1])
    XCTAssertGreaterThan(direction.y, 0.5)
    XCTAssertEqual(length(direction), 1, accuracy: 0.00001)
    for tracked in [SIMD3<Float>(0, 1.5, -0.2), [0.4, 1.7, 0.1], [-0.1, 1.8, -0.5]] {
      let back = frame.trackedPoint(fromWorld: frame.worldPoint(fromTracked: tracked))
      XCTAssertLessThan(length(back - tracked), 0.0001)
    }
    XCTAssertLessThan(length(frame.trackedPoint(fromWorld: .zero) - frame.worldOriginInTracking), 0.0001)
  }

  private func length(_ point: SIMD3<Float>) -> Float {
    sqrt(point.x * point.x + point.y * point.y + point.z * point.z)
  }
}
