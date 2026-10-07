import XCTest

@testable import WorldCore

final class CosmosAndEcologyTests: XCTestCase {
  func testPlanetSystemIsDeterministicAndEachWorldIsDistinct() {
    let first = SolarSystem(seed: 8192)
    let second = SolarSystem(seed: 8192)
    let other = SolarSystem(seed: 17)
    XCTAssertEqual(first.planets.count, 6)
    XCTAssertEqual(first.planets.map(\.seed), second.planets.map(\.seed))
    XCTAssertEqual(first.planets.map(\.center), second.planets.map(\.center))
    XCTAssertEqual(Set(first.planets.map(\.seed)).count, 6)
    XCTAssertNotEqual(first.planets.map(\.seed), other.planets.map(\.seed))
    let maps = first.planets.map { PlanetSurfaceMap.generate($0, width: 64) }
    XCTAssertTrue(
      maps.allSatisfy { $0.color.count == 64 * 32 * 4 && $0.roughness.count == $0.color.count })
    for a in maps.indices {
      for b in maps.indices where a < b { XCTAssertNotEqual(maps[a].color, maps[b].color) }
    }
  }

  func testSpaceDepartureDoesNotImmediatelyRelandAndCanEnterAnotherPlanet() {
    let system = SolarSystem(seed: 8192)
    var ship = SpaceFlight(departing: system.planets[0], heading: 0)
    XCTAssertNil(ship.update(deltaTime: 0, movement: .zero, system: system))
    let destination = system.planets[1]
    ship.position = destination.center + [0, destination.radius + 19, 0]
    XCTAssertEqual(ship.update(deltaTime: 0, movement: .zero, system: system), 1)
    ship.position = system.planets[0].center + [0, system.planets[0].radius + 100, 0]
    XCTAssertNil(ship.update(deltaTime: 0, movement: .zero, system: system))
    XCTAssertTrue(ship.clearedOrigin)
    ship.position = system.planets[0].center + [0, system.planets[0].radius + 19, 0]
    XCTAssertEqual(ship.update(deltaTime: 0, movement: .zero, system: system), 0)
  }

  func testSpaceRetainsMomentumWithGentleDampingAndRestoresTravel() throws {
    let system = SolarSystem(seed: 42)
    var ship = SpaceFlight(departing: system.planets[0], heading: 0)
    ship.position = [10_000, 10_000, 10_000]
    ship.velocity = [0, 0, -30]
    let altitude = ship.position.y
    for _ in 0..<90 { _ = ship.update(deltaTime: 1 / 90, movement: .zero, system: system) }
    XCTAssertEqual(ship.position.y, altitude)
    XCTAssertLessThan(ship.position.z, 10_000)
    XCTAssertLessThan(ship.speed, 30)
    XCTAssertGreaterThan(ship.speed, 0)
    _ = ship.update(deltaTime: 0.05, movement: [0, 1, 0], system: system)
    XCTAssertGreaterThan(ship.position.y, altitude)
    let stop = ship.position
    _ = ship.update(deltaTime: 0.05, movement: .zero, system: system)
    XCTAssertGreaterThan(ship.position.y, stop.y)
    let restored = try JSONDecoder().decode(SpaceFlight.self, from: JSONEncoder().encode(ship))
    XCTAssertEqual(restored.position, ship.position)
    XCTAssertEqual(restored.originIndex, ship.originIndex)
  }

  func testInlandLakesGenerateAboveSeaLevelAndHaveNoTidesOrWindWaves() {
    let terrain = TerrainGenerator(seed: 8192)
    var lake: InlandLake?
    search: for x in -15...15 {
      for z in -15...15 {
        if let candidate = terrain.lake(nearX: x * 128 + 64, z: z * 128 + 64),
          candidate.level>TerrainGenerator.seaLevel,
          SettlementGenerator.site(
            at: .init(candidate.x, candidate.level, candidate.z), terrain: terrain) == nil
        {
          lake = candidate
          break search
        }
      }
    }
    guard let lake else { return XCTFail("Expected inland lakes") }
    XCTAssertGreaterThan(lake.level, TerrainGenerator.seaLevel)
    XCTAssertLessThan(terrain.height(atX: lake.x, z: lake.z), lake.level - 3)
    XCTAssertEqual(terrain.block(at: .init(lake.x, lake.level, lake.z)), .water)
    let early = WorldEnvironment(elapsed: 100)
    let late = WorldEnvironment(elapsed: 400)
    XCTAssertEqual(
      early.water(atX: Float(lake.x), z: Float(lake.z), body: lake.body).height, lake.body.level)
    XCTAssertEqual(
      late.water(atX: Float(lake.x), z: Float(lake.z), body: lake.body).height, lake.body.level)
    XCTAssertNotEqual(early.water(atX: 0, z: 0).height, late.water(atX: 0, z: 0).height)
  }

  func testWaterDisturbancesPropagateFadeAndStayInTheirOwnBody() {
    let body = WaterBody(id: 123, kind: .lake, level: 36)
    var environment = WorldEnvironment(elapsed: 0)
    environment.disturbWater(atX: 0, z: 0, body: body, energy: 0.25)
    environment.advance(0.4)
    XCTAssertNotEqual(environment.water(atX: 0.7, z: 0, body: body).height, body.level)
    XCTAssertEqual(
      environment.water(atX: 0.7, z: 0, body: .init(id: 124, kind: .lake, level: 36)).height, 36)
    environment.advance(6)
    XCTAssertTrue(environment.disturbances.isEmpty)
    XCTAssertEqual(environment.water(atX: 0.7, z: 0, body: body).height, body.level)
  }

  func testSpeciesHaveDistinctMaterialsAndConiferAndWillowShapes() {
    let oak = TreeDescriptor(species: .oak, x: 0, z: 0, ground: 30, height: 5)
    let birch = TreeDescriptor(species: .birch, x: 0, z: 0, ground: 30, height: 6)
    let spruce = TreeDescriptor(species: .spruce, x: 0, z: 0, ground: 30, height: 9)
    let cherry = TreeDescriptor(species: .cherry, x: 0, z: 0, ground: 30, height: 5)
    let willow = TreeDescriptor(species: .willow, x: 0, z: 0, ground: 30, height: 6)
    XCTAssertEqual(oak.block(at: .init(0, 31, 0)), .wood)
    XCTAssertEqual(birch.block(at: .init(0, 31, 0)), .birchWood)
    XCTAssertEqual(spruce.block(at: .init(0, 31, 0)), .spruceWood)
    XCTAssertEqual(cherry.block(at: .init(1, 35, 0)), .cherryLeaves)
    XCTAssertNil(spruce.block(at: .init(3, 41, 0)))
    XCTAssertEqual(willow.block(at: .init(4, 33, 1)), .willowLeaves)
    XCTAssertNotEqual(Block.birchWood.tile(face: 0), Block.wood.tile(face: 0))
  }

  func testMountainPeaksHaveSnowAndNoTreesAboveTreeline() {
    let terrain = TerrainGenerator(seed: 8192)
    var peak: (Int, Int)?
    search: for x in stride(from: -3_000, through: 3_000, by: 80) {
      for z in stride(from: -3_000, through: 3_000, by: 80) {
        if terrain.height(atX: x, z: z) >= 70 {
          peak = (x, z)
          break search
        }
      }
    }
    guard let (x, z) = peak else { return XCTFail("Expected tall mountain ranges") }
    XCTAssertEqual(terrain.surface(atX: x, z: z), .snow)
    XCTAssertNil(terrain.tree(atX: x, z: z))
    XCTAssertLessThan(terrain.height(atX: x, z: z), ChunkData.height)
  }

  func testAllSettlementSizesExistAndCitiesHaveLargerFootprints() {
    let terrain = TerrainGenerator(seed: 8192)
    var found: [SettlementKind: Settlement] = [:]
    for x in -15...15 {
      for z in -15...15 {
        if let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain) {
          found[site.kind] = site
        }
      }
    }
    guard let village = found[.village], let town = found[.town], let city = found[.city] else {
      return XCTFail("Expected villages, towns and cities")
    }
    XCTAssertLessThan(village.radius, town.radius)
    XCTAssertLessThan(town.radius, city.radius)
    XCTAssertLessThan(village.population, city.population)
    XCTAssertEqual(
      city.block(at: .init(city.x + 1, city.floor, city.z), terrain: terrain), .air,
      "Road markings must not obstruct walking")
    for site in found.values {
      XCTAssertFalse(site.block(at: .init(site.x, site.floor, site.z), terrain: terrain)!.isSolid)
    }
  }

  func testSettlementChunkSamplingAndEditsAgreeAtBorders() {
    let terrain = TerrainGenerator(seed: 8192)
    guard let site = SettlementGenerator.site(in: .init(0, 0), terrain: terrain) else {
      return XCTFail("Expected home village")
    }
    let coordinate = BlockPosition(site.center).chunk
    let edit = BlockPosition(coordinate.x * 16 + 15, site.floor + 2, site.z)
    let edits: [BlockPosition: Block] = [edit: .glass]
    let chunk = terrain.generate(coordinate, edits: edits)
    let neighbor = terrain.generate(.init(coordinate.x + 1, coordinate.z), edits: edits)
    for y in (site.floor - 2)...(site.floor + 12) {
      for z in 0..<16 {
        XCTAssertEqual(chunk[16, y, z], neighbor[0, y, z])
        XCTAssertEqual(chunk[15, y, z], neighbor[-1, y, z])
        let p = BlockPosition(coordinate.x * 16 + 8, y, coordinate.z * 16 + z)
        XCTAssertEqual(chunk[8, y, z], edits[p] ?? terrain.block(at: p))
      }
    }
  }

  func testCoastalSettlementFoundationsReachBelowZeroAndMatchGeneratedChunks() {
    let terrain = TerrainGenerator(seed: 8192)
    for x in -15...15 {
      for z in -15...15 {
        guard let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain), site.habitat == .surface else {
          continue
        }
        for (dx, dz) in [
          (-site.radius + 2, -site.radius + 2), (site.radius - 2, site.radius - 2),
          (-site.radius + 2, site.radius - 2), (site.radius - 2, -site.radius + 2),
        ] {
          let p = BlockPosition(site.x + dx, -1, site.z + dz)
          guard terrain.height(atX: p.x, z: p.z) < -2 else { continue }
          XCTAssertEqual(site.block(at: p, terrain: terrain), .stone)
          XCTAssertEqual(terrain.block(at: p), .stone)
          let chunk = terrain.generate(p.chunk)
          XCTAssertEqual(chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16], .stone)
          return
        }
      }
    }
    XCTFail("Expected a settlement pad extending over deep coastal terrain")
  }
}
