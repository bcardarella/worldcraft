import XCTest
import simd

@testable import WorldCore

final class UrbanWeatherTests: XCTestCase {
  let terrain = TerrainGenerator(seed: 8192)
  func testTownAndCityLandUsesAndSportsGroundsAreUsable() {
    for kind in [SettlementKind.town, .city] {
      let site = Settlement(
        id: 1, kind: kind, name: "Town", x: 512, z: 512, floor: 30, ground: .grass)
      let buildings = OwnedHome.properties(in: site, terrain: terrain)
      let uses = Set(buildings.map { $0.building.use })
      XCTAssertTrue(uses.isSuperset(of: [.home, .school, .office]))
      XCTAssertGreaterThanOrEqual(uses.filter(\.shop).count, 4)
      XCTAssertEqual(site.lotUse(x: 0, z: 0, terrain: terrain), .park)
      for field in site.sportsGrounds {
        XCTAssertGreaterThan(field.x1 - field.x0, 60)
        let x = (field.x0 + field.x1) / 2
        let z = (field.z0 + field.z1) / 2
        XCTAssertNotNil(site.sportsGround(atX: x, z: z))
        XCTAssertNil(
          site.building(
            lotX: floorDivide(x - site.x, by: site.spacing),
            lotZ: floorDivide(z - site.z, by: site.spacing), terrain: terrain))
        for dz in -8...8 {
          for dx in -8...8 {
            XCTAssertTrue(
              site.block(at: .init(x + dx, site.floor - 1, z + dz), terrain: terrain)!.isSolid)
            for y in 0...4 {
              XCTAssertEqual(
                site.block(at: .init(x + dx, site.floor + y, z + dz), terrain: terrain), .air)
            }
          }
        }
      }
      let school = site.building(lotX: -1, lotZ: -1, terrain: terrain)!
      let middle = (school.minimum + school.maximum) / 2
      XCTAssertEqual(school.use, .school)
      XCTAssertEqual(school.block(x: middle, y: 2, z: school.minimum), .air)
      XCTAssertTrue(
        (school.minimum...school.maximum).contains {
          school.block(x: $0, y: 8, z: school.minimum) == .lamp
        })
    }
    let village = Settlement(
      id: 1, kind: .village, name: "Village", x: 128, z: 128, floor: 30, ground: .grass)
    XCTAssertTrue(village.sportsGrounds.isEmpty)
  }
  func testSettlementsAreSparseAndRoadsHaveClearDecksAndShallowGrades() {
    let sites = (-10...10).flatMap { x in
      (-10...10).compactMap { SettlementGenerator.site(in: .init(x, $0), terrain: terrain) }
    }
    XCTAssertLessThan(sites.count, 441 / 3)
    let roads = WorldRoads.segments(x: 0, z: 0, width: SettlementGenerator.regionSize * 4, terrain: terrain)
    XCTAssertFalse(roads.isEmpty)
    var bridges = 0
    for segment in roads {
      let d = segment.b - segment.a
      let length = simd_length(SIMD2(d.x, d.z))
      guard length > 0.01 else { continue }
      XCTAssertLessThanOrEqual(abs(d.y) / length, 0.241)
      let midpoint = (segment.a + segment.b) / 2
      let p = BlockPosition(midpoint)
      guard let road = segment.sample(x: p.x, z: p.z) else { continue }
      let column = terrain.column(atX: p.x, z: p.z)
      XCTAssertTrue(road.block(at: .init(p.x, road.floor - 1, p.z), natural: column)!.isSolid)
      XCTAssertEqual(road.block(at: .init(p.x, road.floor + 1, p.z), natural: column), .air)
      if let water = column.water {
        bridges += 1
        XCTAssertGreaterThan(Float(road.floor), water.level + 2)
      }
    }
    XCTAssertGreaterThan(bridges, 0)
  }
  func testRoadChunksMatchQueriesAcrossRegionsAndKeepWaterBelowBridges() {
    let roads = WorldRoads.segments(x: 0, z: 0, width: SettlementGenerator.regionSize * 4, terrain: terrain)
    XCTAssertEqual(roads.count, Set(roads).count)
    var checked = Set<ChunkCoordinate>()
    var bridges = 0
    // Exercise bridges first; land-only segments near the starting village
    // must not consume the whole bounded chunk sample as continents grow.
    let wet = roads.filter {
      let p=BlockPosition(($0.a+$0.b)/2)
      return terrain.column(atX:p.x,z:p.z).water != nil
    }
    for segment in wet + roads {
      let p = BlockPosition((segment.a + segment.b) / 2)
      guard SettlementGenerator.site(at: p, terrain: terrain) == nil,
        !terrain.landmarks.contains(where: { $0.contains(x: p.x, z: p.z) }),
        checked.count < 24, checked.insert(p.chunk).inserted,
        let road = WorldRoads.sample(x: p.x, z: p.z, segments: roads)
      else { continue }
      let column = terrain.column(atX: p.x, z: p.z)
      let chunk = terrain.generate(p.chunk)
      for y in column.height + 1...max(column.height + 1, road.floor + 4) {
        XCTAssertEqual(
          chunk[p.x - p.chunk.x * 16, y, p.z - p.chunk.z * 16],
          terrain.block(at: .init(p.x, y, p.z)), "Road query differs at \(p.x),\(y),\(p.z)")
      }
      if let water = column.water, p.x % 24 != 0, p.z % 24 != 0,
        Int(water.level) - 1 > column.height, Int(water.level) - 1 < road.floor - 2
      {
        XCTAssertEqual(
          chunk[p.x - p.chunk.x * 16, Int(water.level) - 1, p.z - p.chunk.z * 16], .water)
        bridges += 1
      }
    }
    XCTAssertEqual(checked.count, 24)
    XCTAssertGreaterThan(bridges, 0)
  }
  func testConnectingRoadsMeetSettlementStreetsWithoutCliffs() {
    let roads = WorldRoads.segments(x: 0, z: 0, width: SettlementGenerator.regionSize * 4, terrain: terrain)
    var crossings = 0
    for segment in roads {
      let delta = segment.b - segment.a
      let steps = max(1, Int(ceil(simd_length(SIMD2(delta.x, delta.z)))))
      var previous: (height: Int, site: UInt64?)?
      for i in 0...steps {
        let point = BlockPosition(segment.a + delta * Float(i) / Float(steps))
        let site = SettlementGenerator.site(at: point, terrain: terrain)
        guard let road = WorldRoads.sample(x: point.x, z: point.z, segments: roads) else {
          continue
        }
        let height = site?.floor ?? road.floor
        if let previous, previous.site != site?.id {
          XCTAssertLessThanOrEqual(abs(height - previous.height), 1, "Road entrance at \(point)")
          crossings += 1
        }
        previous = (height, site?.id)
      }
    }
    XCTAssertGreaterThan(crossings, 0)
  }
  func testRiverCarvingContinuityAndFlowDriveSwimmingAndFloatingItems() throws {
    var found: SIMD3<Float>?
    for z in stride(from: -1000, through: 1000, by: 16) {
      for x in stride(from: 300, through: 900, by: 4) {
        let column=terrain.column(atX:x,z:z)
        if let body = column.water, body.kind == .river,
          body.level-Float(column.height)>3.5, simd_length(body.current)>1.3 {
          found = [Float(x), body.level - 3, Float(z)]
          break
        }
      }
      if found != nil { break }
    }
    let p = try XCTUnwrap(found)
    let column = terrain.column(atX: Int(p.x), z: Int(p.z))
    let body = try XCTUnwrap(column.water)
    XCTAssertLessThan(Float(column.height), body.level)
    XCTAssertEqual(column.surface, .sand)
    XCTAssertEqual(body.kind, .river)
    let flow = terrain.waterCurrent(at: p, time: 100)
    XCTAssertGreaterThan(simd_length(flow), 1)
    let a = terrain.river(atX: p.x, z: p.z)!
    let b = terrain.river(atX: p.x + 0.01, z: p.z + 0.01)!
    XCTAssertLessThan(simd_distance(a.current, b.current), 0.01)
    let noWaves = WorldEnvironment(elapsed: 100).water(atX: p.x, z: p.z, body: body)
    XCTAssertEqual(noWaves.height, body.level, accuracy: 0.0001)
    func water(_ cell: BlockPosition) -> Block { Float(cell.y) < body.level ? .water : .air }
    var player = PlayerPhysics(position: p)
    var drop = DroppedItem(stack: .init(.block(.wood), count: 1), position: p)
    for _ in 0..<20 {
      player.update(
        deltaTime: 0.05, movement: .zero, jump: false, sprint: false, waterLevel: body.level,
        waterCurrent: flow, block: water)
      drop.update(seconds: 0.05, current: flow, block: water)
    }
    XCTAssertGreaterThan(simd_dot(player.position - p, flow), 1)
    XCTAssertGreaterThan(simd_dot(drop.position - p, flow), 1)
    let bank = FluidMotion.advected(
      [0.7, 10, 0], current: [20, 0, 0], seconds: 0.1, block: { $0.x >= 1 ? .stone : .water })
    XCTAssertLessThan(bank.x, 0.81)
  }
  func testWindIsSpatiallyCoherentAndStormsBringStrongerGusts() {
    let fair = WorldWeather(precipitation: 0, snow: false, cloudCover: 0.2, storminess: 0)
    let storm = WorldWeather(precipitation: 1, snow: false, cloudCover: 1, storminess: 1)
    XCTAssertEqual(fair.formation, .cirrus)
    XCTAssertEqual(storm.formation, .cumulonimbus)
    XCTAssertEqual(
      WorldWeather(precipitation: 0, snow: false, cloudCover: 0.45).formation, .cumulus)
    XCTAssertEqual(
      WorldWeather(precipitation: 0.5, snow: false, cloudCover: 0.8).formation, .stratus)
    var gentle: Float = 0
    var strong: Float = 0
    var variations: [Float] = []
    for t in stride(from: 0.0, through: 120.0, by: 0.5) {
      let a = WorldWind.sample(seed: 8192, time: t, position: [30, 30, 40], weather: storm)
      let b = WorldWind.sample(
        seed: 8192, time: t + 0.01, position: [30.01, 30, 40.01], weather: storm)
      XCTAssertLessThan(simd_distance(a.velocity, b.velocity), 0.25)
      XCTAssertEqual(
        a.velocity,
        WorldWind.sample(seed: 8192, time: t, position: [30, 30, 40], weather: storm).velocity)
      gentle += WorldWind.sample(seed: 8192, time: t, position: [30, 30, 40], weather: fair).speed
      strong += a.speed
      variations.append(a.gust)
    }
    XCTAssertGreaterThan(strong, gentle * 2)
    XCTAssertGreaterThan(variations.max()! - variations.min()!, 0.3)
    XCTAssertNotEqual(
      WorldWind.sample(seed: 8192, time: 50, position: .zero, weather: storm).velocity,
      WorldWind.sample(seed: 8192, time: 50, position: [300, 0, 300], weather: storm).velocity)
  }
  func testRiverDirectionsSurviveWaterPackingAndPlantsHaveAnchoredWindWeights() {
    let body = WaterBody(id: 5, kind: .river, level: 24, current: [0.5, 0, 2])
    var geometry = WaterGeometry()
    geometry.samples = [
      .init(position: [0, 0], depth: 4, body: body), .init(position: [0, 2], depth: 4, body: body),
      .init(position: [2, 0], depth: 4, body: body),
    ]
    geometry.shallowIndices = [0, 1, 2]
    let tile = TerrainTile(x: 0, z: 0, size: 1)
    let batch = WaterMeshBatch(key: .init(tile), geometry: [tile: geometry])
    XCTAssertEqual(
      Float(Float16(bitPattern: UInt16(truncatingIfNeeded: batch.sources[0].identity.w))), 0.5)
    XCTAssertEqual(
      Float(Float16(bitPattern: UInt16(truncatingIfNeeded: batch.sources[0].identity.w >> 16))), 2)
    let vertices = batch.vertices(environment: .init(elapsed: 1))
    XCTAssertEqual(vertices[0].py, 24, accuracy: 0.001)
    XCTAssertEqual(vertices[0].uv.x, 0.95, accuracy: 0.001)
    XCTAssertEqual(vertices[0].uv.y, 0.8, accuracy: 0.001)
    let plant = SurfaceDecorationMesher.mesh(
      [.init(position: .init(0, 30, 0), kind: .grass, scale: 1)], chunk: .init(0, 0))
    XCTAssertEqual(plant.windWeights.count, plant.positions.count)
    XCTAssertGreaterThan(plant.windWeights.max() ?? 0, 0)
    let packed = PackedTerrainMesh(plant)
    XCTAssertTrue(packed.vertices.contains { $0.normal.w != 0 })
    XCTAssertEqual(MemoryLayout<TerrainVertex>.stride, 40)
  }
}
