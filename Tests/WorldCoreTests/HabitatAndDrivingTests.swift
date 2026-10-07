import XCTest
@testable import WorldCore

final class HabitatAndDrivingTests: XCTestCase {
  private let terrain = TerrainGenerator(seed: 8192)
  private func reef() throws -> Settlement {
    for z in -8...8 { for x in -8...8 {
      if let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain), site.habitat == .aquatic { return site }
    } }
    return try XCTUnwrap(nil as Settlement?, "Expected a procedural underwater village")
  }

  func testUnderwaterFrostCoastsAndLakeBedsHaveSediment() {
    let frost = TerrainGenerator(seed: 8192, style: .frost)
    var ocean = 0, lakes = 0, drySnow = 0
    for z in stride(from: -1400, through: 1400, by: 13) {
      for x in stride(from: -1400, through: 1400, by: 13) {
        let column = frost.column(atX: x, z: z)
        if let body = column.water, Float(column.height) < body.level {
          XCTAssertEqual(column.surface, .sand)
          if body.kind == .ocean { ocean += 1 } else { lakes += 1 }
        } else if column.surface == .snow { drySnow += 1 }
      }
    }
    XCTAssertGreaterThan(ocean, 0); XCTAssertGreaterThan(lakes, 0); XCTAssertGreaterThan(drySnow, 0)
  }

  func testSolarVillagesAndTownsHaveHeatResistantGrammarAndRoles() throws {
    let sun = SolarSystem(seed: 8192).sun.terrain
    var villages = 0, towns = 0
    for z in -3...3 { for x in -3...3 {
      guard let site = SettlementGenerator.site(in: .init(x, z), terrain: sun) else { continue }
      XCTAssertEqual(site.habitat, .solar)
      if site.kind == .town { towns += 1 } else { villages += 1 }
      XCTAssertEqual(site.name, SettlementGenerator.site(in: .init(x, z), terrain: sun)?.name)
      XCTAssertEqual(site.ground, .basalt)
      let building = try XCTUnwrap(site.building(lotX: -1, lotZ: -1, terrain: sun))
      XCTAssertTrue(building.solar)
      for bx in building.minimum...building.maximum { for bz in building.minimum...building.maximum {
        for y in 0...(building.height + 5) {
          XCTAssertFalse([Block.snow, .wood, .leaves, .grass].contains(building.block(x: bx, y: y, z: bz)))
        }
      } }
      let person = ResidentState(index: 0, site: site)
      XCTAssertNotEqual(person.workDescription, person.role.work)
      XCTAssertEqual(NPCDecisionContext(resident: person, neighbors: []).responsibilities, person.workDescription)
    } }
    XCTAssertGreaterThan(villages, 0); XCTAssertGreaterThan(towns, 0)
  }

  func testReefHousesStayFloodedWithOpenDoorsAndVerticalPassages() throws {
    let site = try reef()
    XCTAssertLessThan(Float(site.floor + 14), try XCTUnwrap(site.waterLevel) - 1)
    let house = try XCTUnwrap(site.building(lotX: -1, lotZ: -1, terrain: terrain))
    let mid = (house.minimum + house.maximum) / 2
    func block(_ x: Int, _ y: Int, _ z: Int) -> Block? {
      site.block(at: .init(site.x - site.spacing + x, site.floor + y, site.z - site.spacing + z), terrain: terrain)
    }
    for y in 1...5 { XCTAssertEqual(block(mid, y, house.minimum), .water) }
    for y in 1...(house.height + 4) { XCTAssertEqual(block(mid, y, mid), .water) }
    for x in house.minimum...house.maximum { for z in house.minimum...house.maximum {
      for y in 0...(house.height + 4) { XCTAssertNotEqual(block(x, y, z), .snow) }
    } }
    XCTAssertEqual(site.block(at: .init(site.x, site.floor + 2, site.z), terrain: terrain), .water)
    XCTAssertEqual(site.block(at: .init(site.x, Int(site.waterLevel!), site.z), terrain: terrain), .air)
    XCTAssertTrue(site.setting.contains("swimming"))
  }

  func testReefChunkBordersAndWaterSurfaceAgreeWithDirectSampling() throws {
    let site = try reef(), coordinate = BlockPosition(site.center).chunk
    let chunk = terrain.generate(coordinate), other = terrain.generate(.init(coordinate.x + 1, coordinate.z))
    for y in (site.floor - 2)...Int(site.waterLevel!) { for z in 0..<16 {
      XCTAssertEqual(chunk[16, y, z], other[0, y, z])
      let p = BlockPosition(coordinate.x * 16 + 8, y, coordinate.z * 16 + z)
      XCTAssertEqual(chunk[8, y, z], terrain.block(at: p))
    } }
    let surface = WaterGeometry(WaterPatch.build(chunk, terrain: terrain))
    XCTAssertFalse(surface.isEmpty)
    XCTAssertTrue(surface.samples.allSatisfy { $0.body.level == site.waterLevel })
    let proxy = TerrainSurface.build(.init(x: floorDivide(coordinate.x, by: 2) * 2, z: floorDivide(coordinate.z, by: 2) * 2, size: 2), terrain: terrain)
    XCTAssertFalse(proxy.water.isEmpty)
    XCTAssertTrue(proxy.water.samples.allSatisfy { $0.body.level == site.waterLevel })
  }

  func testAquaPeopleHaveDifferentDepthsAndCanReachThem() throws {
    let site = try reef()
    let people = (0..<site.population).map { ResidentState(index: $0, site: site) }
    XCTAssertGreaterThan(Set(people.map(\.home.y)).count, 2)
    let water: (BlockPosition) -> Block = { p in site.block(at: p, terrain: self.terrain) ?? .stone }
    for person in people {
      XCTAssertNotNil(ResidentNavigation.swimPosition(at: person.home, block: water))
      XCTAssertNotNil(ResidentNavigation.swimPosition(at: person.workplace, block: water))
      XCTAssertNotEqual(person.roleName, person.role.rawValue.capitalized)
    }
    let start = site.center + [0.5, 2, 0.5], end = site.center + [0.5, 10, 0.5]
    let path = ResidentNavigation.path(from: start, to: end, swimming: true, block: water)
    XCTAssertEqual(path.last, end)
    XCTAssertGreaterThan(Set(path.map(\.y)).count, 4)
    XCTAssertTrue(path.allSatisfy { ResidentNavigation.swimPosition(at: $0, block: water) != nil })
  }

  func testSwimmingRoutesAvoidSolidsAirAndLava() {
    let water: (BlockPosition) -> Block = { p in
      if p.y < 0 { return .sand }; if p.y >= 16 { return .air }
      if p.x == 3 && p.y < 6 { return .glass }
      return .water
    }
    var route: [SIMD3<Float>] = []
    for _ in 0..<4 {
      let start = route.last ?? [0.5, 1, 0.5]
      if start == [6.5, 1, 0.5] { break }
      route += ResidentNavigation.path(from: start, to: [6.5, 1, 0.5], swimming: true, block: water)
    }
    XCTAssertEqual(route.last, [6.5, 1, 0.5])
    XCTAssertTrue(route.contains { $0.y >= 6 })
    XCTAssertTrue(route.allSatisfy { ResidentNavigation.swimPosition(at: $0, block: water) != nil })
    XCTAssertNil(ResidentNavigation.swimPosition(at: [0.5, 14, 0.5], block: water))
    XCTAssertNil(ResidentNavigation.swimPosition(at: [0.5, 1, 0.5], block: { _ in .lava }))
    XCTAssertTrue(ResidentNavigation.path(from: [0.5, 1, 0.5], to: [1.5, 1, 0.5], maximumVisited: 0, swimming: true, block: water).isEmpty)
  }

  func testLavaMovesSlowlyAndKeepsAnalyticNormalsAndNoTide() {
    let x: Float = 7, z: Float = 12, epsilon: Float = 0.01
    let environment = WorldEnvironment(elapsed: 457)
    let sample = environment.water(atX: x, z: z, body: .lava)
    let dx = (environment.water(atX: x + epsilon, z: z, body: .lava).height - environment.water(atX: x - epsilon, z: z, body: .lava).height) / (2 * epsilon)
    XCTAssertEqual(-sample.normal.x / sample.normal.y, dx, accuracy: 0.001)
    XCTAssertLessThan(abs(WorldEnvironment(elapsed: 457.05).water(atX: x, z: z, body: .lava).height - sample.height), 0.008)
    for t in stride(from: 0.0, through: 1200.0, by: 13) {
      XCTAssertLessThan(abs(WorldEnvironment(elapsed: t).water(atX: x, z: z, body: .lava).height - WaterBody.lava.level), 0.28)
    }
    var lake = environment
    lake.disturbWater(atX: x, z: z, body: .lava)
    XCTAssertEqual(lake.water(atX: x + 1, z: z, body: .ocean).height,
      environment.water(atX: x + 1, z: z, body: .ocean).height)
  }

  func testNewBlocksAppendSaveIdentifiersAndUseSeparateAtlasCells() {
    XCTAssertEqual(Block.lava.rawValue, 18)
    XCTAssertEqual(Block.basalt.rawValue, 19); XCTAssertEqual(Block.coral.rawValue, 20); XCTAssertEqual(Block.limestone.rawValue, 21)
    XCTAssertEqual(Set([Block.basalt, .coral, .limestone].map { $0.tile(face: 2) }).count, 3)
  }

  func testVehicleSavesAreBackwardCompatibleAndValidateTheirPayload() throws {
    let car = VehicleRecord(id: 12, siteID: 9, position: [1, 24, -3], heading: 0.5, variant: 2, solar: true)
    var save = WorldSave(seed: 7, edits: [], player: [1, 24, 0], flying: false, heading: 0, selectedSlot: 0, vehicles: [car])
    XCTAssertTrue(save.isValid)
    let decoded = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    XCTAssertEqual(decoded.vehicles?.first?.position, car.position)
    save.vehicles = [.init(id: 12, siteID: 9, position: [1], heading: 0, variant: 0, solar: false)]
    XCTAssertFalse(save.isValid)
    save.vehicles = nil
    XCTAssertTrue(try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save)).isValid)
  }

  private func flat(_ p: BlockPosition) -> Block { p.y < 0 ? .stone : .air }
  func testAnalogThrottleSteeringAndReverse() {
    var slow = VehiclePhysics(position: .zero), fast = slow
    for _ in 0..<120 {
      slow.update(deltaTime: 1/60, throttle: 0.3, turn: 0, brake: 0, block: flat)
      fast.update(deltaTime: 1/60, throttle: 1, turn: 0, brake: 0, block: flat)
    }
    XCTAssertGreaterThan(fast.speed, slow.speed * 2)
    XCTAssertEqual(fast.position.y, 0)
    var gentle = VehiclePhysics(position: .zero), sharp = gentle
    for _ in 0..<60 {
      gentle.update(deltaTime: 1/60, throttle: 0.5, turn: 0.25, brake: 0, block: flat)
      sharp.update(deltaTime: 1/60, throttle: 0.5, turn: 1, brake: 0, block: flat)
    }
    XCTAssertGreaterThan(abs(sharp.heading), abs(gentle.heading) * 2)
    XCTAssertGreaterThan(sharp.position.x, 0)
    var reverse = VehiclePhysics(position: .zero)
    for _ in 0..<60 { reverse.update(deltaTime: 1/60, throttle: -1, turn: 1, brake: 0, block: flat) }
    XCTAssertLessThan(reverse.speed, 0); XCTAssertGreaterThan(reverse.position.z, 0); XCTAssertGreaterThan(reverse.heading, 0)
  }

  func testCarsDoNotTunnelIntoWallsWaterOrUnloadedCells() {
    for barrier in [Block.stone, .water, .lava] {
      let world: (BlockPosition) -> Block = { p in p.z < -10 ? barrier : self.flat(p) }
      var car = VehiclePhysics(position: .zero)
      for _ in 0..<200 { car.update(deltaTime: 0.05, throttle: 1, turn: 0, brake: 0, block: world) }
      XCTAssertGreaterThan(car.position.z, -8)
      XCTAssertEqual(car.speed, 0)
      XCTAssertTrue(VehiclePhysics.isClear(at: car.position, heading: car.heading, block: world))
    }
  }

  func testVillageCarsFitRoadsAndHaveAnExitInNarrowStreets() throws {
    let site = try XCTUnwrap(SettlementGenerator.site(in: .init(0, 0), terrain: terrain))
    let block: (BlockPosition) -> Block = { site.block(at: $0, terrain: self.terrain) ?? .stone }
    let car = VehiclePhysics(position: site.center + [0.5, 0, 6.5])
    XCTAssertTrue(VehiclePhysics.isClear(at: car.position, heading: 0, block: block))
    let exit = try XCTUnwrap(car.exitPosition(block: block))
    XCTAssertFalse(PlayerPhysics(position: exit).collides(at: exit, block: block))
    XCTAssertTrue(abs(exit.x - car.position.x) > VehiclePhysics.halfWidth + PlayerPhysics.radius
      || abs(exit.z - car.position.z) > VehiclePhysics.halfLength + PlayerPhysics.radius)
  }

  func testWalkingAndFlyingCannotPassThroughParkedCars() {
    let car = VehiclePhysics(position: .zero, heading: 0.4)
    for flying in [false, true] {
      var player = PlayerPhysics(position: [0, 0.02, 7])
      player.flying = flying
      for _ in 0..<100 {
        player.update(deltaTime: 1/60, movement: [0, 0, -1], jump: false, sprint: false,
          block: flat, occupied: car.overlapsPlayer)
      }
      XCTAssertFalse(car.overlapsPlayer(at: player.position))
      XCTAssertGreaterThan(player.position.z, 2)
    }
    XCTAssertFalse(car.overlapsPlayer(at: [0, VehiclePhysics.height, 0]))
    XCTAssertTrue(car.overlapsPlayer(at: [0, 0, 0]))
  }

  func testCarClimbsOneBlockButNotHighWalls() {
    let world: (BlockPosition) -> Block = { p in p.y < (p.z < -8 ? 1 : 0) ? .stone : .air }
    var car = VehiclePhysics(position: .zero)
    for _ in 0..<180 { car.update(deltaTime: 1/60, throttle: 0.7, turn: 0, brake: 0, block: world) }
    XCTAssertLessThan(car.position.z, -12); XCTAssertEqual(car.position.y, 1)
  }

  func testBrakingAndSafeExitsRejectBlockedWetOrMovingExits() {
    var car = VehiclePhysics(position: .zero)
    XCTAssertNotNil(car.exitPosition(block: flat))
    for _ in 0..<120 { car.update(deltaTime: 1/60, throttle: 1, turn: 0, brake: 0, block: flat) }
    XCTAssertNil(car.exitPosition(block: flat))
    for _ in 0..<120 { car.update(deltaTime: 1/60, throttle: 0, turn: 0, brake: 1, block: flat) }
    XCTAssertEqual(car.speed, 0)
    let exit = car.exitPosition(block: flat)
    XCTAssertNotNil(exit)
    XCTAssertGreaterThan(abs(exit!.x - car.position.x), VehiclePhysics.halfWidth + PlayerPhysics.radius)
    XCTAssertNil(car.exitPosition(block: { _ in .stone }))
    XCTAssertNil(car.exitPosition(block: { p in p.y < 0 ? .stone : .water }))
    XCTAssertNil(car.exitPosition(block: flat, occupied: { _ in true }))
  }
}
