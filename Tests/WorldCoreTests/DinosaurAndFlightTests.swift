import XCTest
@testable import WorldCore

final class DinosaurAndFlightTests: XCTestCase {
  private func flat(_ p: BlockPosition) -> Block { p.y <= 0 ? .grass : .air }

  func testRexChasesNearbyPlayersButIgnoresDistantOrAirborneOnes() {
    var rex = RexState(id: 42, color: .pink, baby: false, position: [0, 1, 0])
    for i in 0..<30 { _ = rex.update(deltaTime: 1 / 60, time: Double(i) / 60, player: [0, 1, -9], block: flat) }
    XCTAssertEqual(rex.mood, .chasing)
    XCTAssertLessThan(rex.position.z, -2)
    _ = rex.update(deltaTime: 0.05, time: 1, player: [0, 80, -9], block: flat)
    XCTAssertEqual(rex.mood, .wandering)
    _ = rex.update(deltaTime: 0.05, time: 1, player: [100, 1, 100], block: flat)
    XCTAssertEqual(rex.mood, .wandering)
  }

  func testChompsHaveWindupContactAndCooldownAndRespectWalls() {
    var rex = RexState(id: 1, color: .purple, baby: false, position: [0, 1, 0])
    let target = SIMD3<Float>(0, 1, -2.6)
    XCTAssertFalse(rex.update(deltaTime: 0.05, time: 0, player: target, block: flat))
    XCTAssertEqual(rex.mood, .windingUp)
    var hits = 0
    for i in 0..<24 { if rex.update(deltaTime: 0.05, time: Double(i) * 0.05, player: target, block: flat) { hits += 1 } }
    XCTAssertEqual(hits, 1)
    var blocked = RexState(id: 1, color: .yellow, baby: false, position: [0, 1, 0])
    for i in 0..<120 {
      XCTAssertFalse(blocked.update(deltaTime: 1 / 60, time: Double(i) / 60, player: target) {
        $0.z == -1 && $0.y > 0 ? .brick : self.flat($0)
      })
    }
    XCTAssertGreaterThan(blocked.position.z, -1)
  }

  func testEscapingAnOpenJawAvoidsTheBiteAndBabiesAlsoChomp() {
    var rex = RexState(id: 1, color: .mint, baby: false, position: [0, 1, 0])
    _ = rex.update(deltaTime: 0.05, time: 0, player: [0, 1, -2.6], block: flat)
    for i in 0..<20 { XCTAssertFalse(rex.update(deltaTime: 0.05, time: Double(i) * 0.05, player: [0, 1, -10], block: flat)) }
    var baby = RexState(id: 2, color: .pink, baby: true, position: [0, 1, 0])
    var hits = 0
    for i in 0..<20 { if baby.update(deltaTime: 0.05, time: Double(i) * 0.05, player: [0, 1, -1.3], block: flat) { hits += 1 } }
    XCTAssertEqual(hits, 1)
    XCTAssertLessThan(baby.scale, rex.scale)
  }

  func testSeededFamiliesHaveAdultsBabiesAndColorVariety() {
    let terrain = TerrainGenerator(seed: 8192)
    var families: [[RexState]] = []
    for x in -10...10 { for z in -10...10 {
      // Sample across continents, rather than only the initial mountain.
      let chunk = terrain.generate(.init(x * 16, z * 16))
      let origin = chunk.coordinate
      let block: (BlockPosition) -> Block = { chunk[$0.x - origin.x * 16, $0.y, $0.z - origin.z * 16] }
      let family = RexState.family(in: origin, terrain: terrain, block: block)
      if !family.isEmpty {
        families.append(family)
        XCTAssertEqual(family.map(\.id), RexState.family(in: origin, terrain: terrain, block: block).map(\.id))
        XCTAssertFalse(family[0].baby)
        XCTAssertTrue(family.dropFirst().allSatisfy { $0.baby && $0.color == family[0].color })
      }
    } }
    XCTAssertGreaterThan(families.count, 2)
    XCTAssertTrue(families.contains { $0.count > 1 })
    XCTAssertGreaterThan(Set(families.map { $0[0].color }).count, 1)
    XCTAssertTrue(RexState.family(in: .init(0, 0), terrain: .init(seed: 8192, style: .solar), block: flat).isEmpty)
  }

  func testRexAndPlantSculpturesHaveSolidOutwardFacesAndBoundedGeometry() {
    let models = PlantKind.allCases.map { SurfaceDecorationMesher.shape($0).mesh(cellSize: 0.125) }
      + RexSculpture.Part.allCases.map { RexSculpture.mesh($0) }
    for mesh in models {
      XCTAssertFalse(mesh.positions.isEmpty)
      XCTAssertLessThan(mesh.faceCount, 400)
      XCTAssertEqual(Set(mesh.normals).count, 6)
      for i in stride(from: 0, to: mesh.indices.count, by: 3) {
        let a = mesh.positions[Int(mesh.indices[i])]
        let b = mesh.positions[Int(mesh.indices[i + 1])] - a, c = mesh.positions[Int(mesh.indices[i + 2])] - a
        let cross = SIMD3(b.y*c.z-b.z*c.y, b.z*c.x-b.x*c.z, b.x*c.y-b.y*c.x)
        let n = mesh.normals[Int(mesh.indices[i])]
        XCTAssertGreaterThan(cross.x*n.x+cross.y*n.y+cross.z*n.z, 0)
      }
    }
  }

  func testSpaceThrustFollowsPitchYawAndAnalogDeflection() {
    let up = LocomotionInput.spaceMovement([0, 1], ascend: 0, heading: 0, pitch: .pi / 2)
    XCTAssertEqual(up.y, 1, accuracy: 0.00001)
    XCTAssertEqual(up.z, 0, accuracy: 0.00001)
    let left = LocomotionInput.spaceMovement([0, 1], ascend: 0, heading: .pi / 2, pitch: 0)
    XCTAssertEqual(left.x, -1, accuracy: 0.00001)
    let strafe = LocomotionInput.spaceMovement([1, 0], ascend: 0, heading: 0, pitch: 1)
    XCTAssertEqual(strafe, [1, 0, 0])
    let system = SolarSystem(seed: 0)
    var gentle = SpaceFlight(departing: system.planets[0], heading: 0), full = gentle
    gentle.position = [20_000, 20_000, 20_000]; full.position = gentle.position
    for _ in 0..<60 {
      _ = gentle.update(deltaTime: 1 / 60, movement: up * 0.4, system: system)
      _ = full.update(deltaTime: 1 / 60, movement: up, system: system)
    }
    XCTAssertEqual(gentle.velocity.y, full.velocity.y * 0.4, accuracy: 0.001)
    XCTAssertGreaterThan(full.position.y, 20_000)
    let previous = full.velocity.y
    _ = full.update(deltaTime: 0.05, movement: [0, 0, -1], system: system)
    XCTAssertGreaterThan(full.velocity.y, 0)
    XCTAssertLessThan(full.velocity.y, previous)
    XCTAssertLessThan(full.velocity.z, 0)
  }

  func testSpaceVelocityIsTimeStepStableAndBounded() {
    let system = SolarSystem(seed: 1)
    var a = SpaceFlight(departing: system.planets[0], heading: 0), b = a
    a.position = [20_000, 20_000, 20_000]; b.position = a.position
    for _ in 0..<90 { _ = a.update(deltaTime: 1 / 90, movement: [0, 0, -1], system: system) }
    for _ in 0..<60 { _ = b.update(deltaTime: 1 / 60, movement: [0, 0, -1], system: system) }
    XCTAssertEqual(a.velocity.z, b.velocity.z, accuracy: 0.01)
    for _ in 0..<900 { _ = a.update(deltaTime: 1 / 90, movement: [1, 1, 1], sprint: true, system: system) }
    XCTAssertLessThanOrEqual(a.speed, 240.001)
    let before = a.position
    _ = a.update(deltaTime: 0, movement: [1, 1, 1], system: system)
    XCTAssertEqual(a.position, before)
  }

  func testHalfMetreBlocksKeepPhysicalHeadParallaxAndPlayerDimensions() {
    XCTAssertEqual(WorldScale.metres(PlayerPhysics.height), 1.75)
    XCTAssertEqual(WorldScale.metres(PlayerPhysics.eyeHeight), 1.62)
    let frame = PlayerFrame(referenceEye: [0, 1.62, 0], feet: [8, 30, 9], heading: 0)
    let leaning = frame.worldPoint(fromTracked: [0.2, 1.62, 0])
    XCTAssertEqual(leaning.x - frame.eye.x, 0.4, accuracy: 0.00001)
    let cube = frame.trackedPoint(fromWorld: frame.eye + [1, 0, 0])
    XCTAssertEqual(cube.x, 0.5)
    let tracked = frame.trackedPoint(fromWorld: leaning)
    XCTAssertEqual(tracked.x, 0.2, accuracy: 0.00001)
    XCTAssertEqual(tracked.y, 1.62, accuracy: 0.00001)
    XCTAssertEqual(tracked.z, 0, accuracy: 0.00001)
  }

  func testAtlasFacesUseCorrectRowsTilesAndPaddedUvs() {
    for block in [Block.grass, .dirt, .stone, .wood, .birchWood, .cherryLeaves] {
      var chunk = ChunkData(coordinate: .init(0, 0)); chunk[3, 3, 3] = block
      let mesh = VoxelMesher.build(chunk)
      for face in 0..<6 {
        let coordinates = Array(mesh.textureCoordinates[(face * 4)..<(face * 4 + 4)])
        let u = coordinates.map(\.x).reduce(0, +) / 4, v = coordinates.map(\.y).reduce(0, +) / 4
        let tile = Int((1 - v) * 8) * 16 + Int(u * 16)
        XCTAssertEqual(tile % 32, block.tile(face: face))
        let px = coordinates.map { $0.x * 1024 }, py = coordinates.map { (1 - $0.y) * 512 }
        XCTAssertEqual(px.max()! - px.min()!, 55, accuracy: 0.001)
        XCTAssertEqual(py.max()! - py.min()!, 55, accuracy: 0.001)
      }
    }
    XCTAssertEqual(Block.grass.tile(face: 2), 0)
    XCTAssertEqual(Block.grass.tile(face: 3), Block.dirt.tile(face: 2))
    XCTAssertNotEqual(Block.wood.tile(face: 2), Block.wood.tile(face: 0))
  }

  func testHorizonBatchesPreserveNegativeWorldPositionsAndReduceSubmissions() {
    let plan = ChunkStreamingPlan(center: .init(0, 0), radius: 32)
    let near = plan.chunks.values.filter { $0 == .full }.count
    let keys = Set(plan.chunks.filter { $0.value != .full }.map { HorizonBatchKey(coordinate: $0.key, detail: $0.value) })
    XCTAssertLessThan(keys.count + near, plan.chunks.count / 4)
    var chunk = ChunkData(coordinate: .init(-1, -1)); chunk[0, 30, 0] = .stone
    let original = VoxelMesher.build(chunk)
    let key = HorizonBatchKey(coordinate: chunk.coordinate, detail: .distant)
    let combined = key.merge([chunk.coordinate: original])
    XCTAssertEqual(combined.indices, original.indices)
    for i in original.positions.indices {
      XCTAssertEqual(combined.positions[i] + key.origin, original.positions[i] + chunk.coordinate.origin)
    }
  }

  func testHalfMetreSettlementDoorHasHumanHeadroom() throws {
    let terrain = TerrainGenerator(seed: 8192)
    let site = try XCTUnwrap(SettlementGenerator.site(in: .init(0, 0), terrain: terrain))
    // Cottage entrance in the first complete plot. Floor, doorway and ceiling
    // must accommodate the physical-size player after changing the block scale.
    let middle = (3 + site.spacing - 3) / 2
    for y in 1...4 {
      XCTAssertEqual(site.block(at: .init(site.x + middle, site.floor + y, site.z + 3), terrain: terrain), .air)
    }
    XCTAssertLessThan(PlayerPhysics.height, 4)
  }

  func testVerticalSpaceSteeringSurvivesSavingAndGroundClampRemains() throws {
    XCTAssertEqual(LocomotionInput.clampSpacePitch(3), .pi / 2)
    XCTAssertEqual(LocomotionInput.clampSpacePitch(-3), -.pi / 2)
    var save = WorldSave(seed: 8192, edits: [], player: [0, 80, 0], flying: true,
      heading: 0, selectedSlot: 0, space: .init(departing: SolarSystem(seed: 8192).planets[0], heading: 0), viewPitch: .pi / 2)
    XCTAssertTrue(save.isValid)
    let restored = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    XCTAssertEqual(restored.viewPitch, .pi / 2)
    save.space = nil
    XCTAssertFalse(save.isValid)
    save.viewPitch = LocomotionInput.clampLookPitch(save.viewPitch!)
    XCTAssertTrue(save.isValid)
  }
}
