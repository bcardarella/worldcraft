import XCTest
import simd

@testable import WorldCore

final class CityScaleTests: XCTestCase {
  let terrain = TerrainGenerator(seed: 8192)
  func site(_ kind: SettlementKind) -> Settlement {
    .init(id: 1, kind: kind, name: "Scale", x: 512, z: 512, floor: 30, ground: .grass)
  }
  func testCitiesHaveMetropolitanFootprintsAndTallVariedDowntowns() {
    let city = site(.city)
    let town = site(.town)
    XCTAssertGreaterThanOrEqual(WorldScale.metres(Float(city.radius * 2)), 400)
    XCTAssertGreaterThanOrEqual(WorldScale.metres(Float(town.radius * 2)), 180)
    var central: [Int] = []
    var outer: [Int] = []
    for z in -6..<6 {
      for x in -6..<6 {
        guard let building = city.building(lotX: x, lotZ: z, terrain: terrain) else { continue }
        XCTAssertGreaterThanOrEqual(
          WorldScale.metres(Float(building.maximum - building.minimum + 1)), 16)
        XCTAssertLessThan(city.floor + building.height + 6, ChunkData.height)
        if max(abs(x * 2 + 1), abs(z * 2 + 1)) <= 5 {
          central.append(building.height)
        } else {
          outer.append(building.height)
        }
      }
    }
    // The city stadium now reserves 25 lots rather than a 16-lot field.
    // Its surrounding city still needs a substantial built neighbourhood.
    XCTAssertGreaterThan(central.count + outer.count, 90)
    XCTAssertGreaterThan(Set(central + outer).count, 5)
    XCTAssertGreaterThan(
      Float(central.reduce(0, +)) / Float(central.count),
      Float(outer.reduce(0, +)) / Float(outer.count) + 15)
    XCTAssertGreaterThan(WorldScale.metres(Float(central.max()!)), 40)
  }
  func testWideCarriagewaysAndPavementsStayClearAcrossEntireCity() {
    for kind in [SettlementKind.town, .city] {
      let site = site(kind)
      XCTAssertGreaterThanOrEqual(WorldScale.metres(Float(site.streetHalfWidth * 2 + 1)), 8.5)
      XCTAssertGreaterThanOrEqual(WorldScale.metres(Float(site.sidewalkWidth)), 1.5)
      for along in stride(from: -site.radius + 4, through: site.radius - 4, by: 3) {
        for across
          in -(site.streetHalfWidth + site.sidewalkWidth)...(site.streetHalfWidth
          + site.sidewalkWidth)
        {
          let p = BlockPosition(site.x + across, site.floor, site.z + along)
          XCTAssertTrue(site.block(at: .init(p.x, p.y - 1, p.z), terrain: terrain)!.isSolid)
          for y in 0...5 {
            XCTAssertEqual(site.block(at: .init(p.x, p.y + y, p.z), terrain: terrain), .air)
          }
        }
        for lane: Float in [-4.5, 4.5] {
          let p = site.center + [lane, 0, Float(along) + 0.5]
          XCTAssertTrue(
            VehiclePhysics.isClear(
              at: p, heading: 0, block: { site.block(at: $0, terrain: terrain) ?? .stone }))
        }
      }
    }
  }
  func testCitiesFitTheirRegionsAndRemainDiscoverableAtCorners() {
    var cities = 0
    for z in -16...16 {
      for x in -16...16 {
        guard let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain) else {
          continue
        }
        for dx in [-site.radius + 1, site.radius - 1] {
          for dz in [-site.radius + 1, site.radius - 1] {
            let corner = BlockPosition(site.x + dx, site.floor, site.z + dz)
            XCTAssertEqual(SettlementGenerator.site(at: corner, terrain: terrain)?.id, site.id)
            XCTAssertEqual(site.distanceSquared(to: corner.center), 0)
            XCTAssertEqual(floorDivide(corner.x, by: SettlementGenerator.regionSize), x)
            XCTAssertEqual(floorDivide(corner.z, by: SettlementGenerator.regionSize), z)
          }
        }
        if site.kind == .city { cities += 1 }
      }
    }
    XCTAssertGreaterThan(cities, 1)
  }
  func testCarsAndHomesSpanTheCityWithLocalDailyDestinations() {
    let city = site(.city)
    let homes = OwnedHome.properties(in: city, terrain: terrain)
    XCTAssertGreaterThan(homes.count, 90)
    for home in homes {
      for purpose in [MeetingPurpose.work, .meal, .leisure] {
        let point = city.meetingPoint(index: home.ownerIndex, purpose: purpose, near: home.entrance)
        XCTAssertLessThan(simd_distance(point, home.entrance), Float(city.spacing * 2))
        XCTAssertTrue(city.contains(.init(point)))
        XCTAssertNotNil(
          ResidentNavigation.walkingPosition(
            at: point, block: { city.block(at: $0, terrain: terrain) ?? .stone }), "\(purpose) point=\(point) home=\(home.entrance)")
      }
    }
    let points = (0..<city.vehicleCount).map { city.vehiclePosition($0) }
    XCTAssertGreaterThan(points.map(\.x).max()! - points.map(\.x).min()!, 600)
    XCTAssertGreaterThan(points.map(\.z).max()! - points.map(\.z).min()!, 600)
    for p in points {
      XCTAssertTrue(
        VehiclePhysics.isClear(
          at: p, heading: 0, block: { city.block(at: $0, terrain: terrain) ?? .stone }))
    }
    XCTAssertGreaterThan(city.population, 200)
    XCTAssertLessThanOrEqual(city.activePopulationLimit, 48)
  }
  func testDistantBuildingsDoNotCoverTheStreetGrid() throws {
    let city = try XCTUnwrap(
      (-8...8).lazy.flatMap { x in
        (-8...8).compactMap { SettlementGenerator.site(in: .init(x, $0), terrain: self.terrain) }
      }.first { $0.kind == .city })
    let tile = TerrainTile(
      x: floorDivide(city.x - 96, by: 256) * 16, z: floorDivide(city.z - 96, by: 256) * 16, size: 16
    )
    let mesh = TerrainSurface.build(tile, terrain: terrain).mesh
    var walls = 0
    for i in stride(from: 0, to: mesh.positions.count, by: 4) {
      let center =
        mesh.positions[i..<i + 4].reduce(.zero, +) / 4
        + SIMD3<Float>(Float(tile.x * 16), 0, Float(tile.z * 16))
      guard center.y > Float(city.floor + 2), city.contains(.init(center)) else { continue }
      walls += 1
      XCTAssertFalse(
        city.isRoad(atX: Int(floor(center.x)), z: Int(floor(center.z))),
        "Distant geometry covers a street at \(center)")
    }
    XCTAssertGreaterThan(walls, 20)
  }
}
