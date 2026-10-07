import XCTest
import simd
@testable import WorldCore

final class RocketTests: XCTestCase {
  private let system = SolarSystem(seed: 8192)
  private func port(_ index: Int) throws -> RocketPort {
    let terrain = system.planets[index].terrain
    return try XCTUnwrap(RocketPort.nearest(to: terrain.spawn(), terrain: terrain))
  }
  private func flight() throws -> RocketJourney {
    try .init(originPlanet: 0, destinationPlanet: 1, origin: port(0), destination: port(1), passenger: [1, 0, 2])
  }
  private func reach(_ phase: RocketPhase, flight: inout RocketJourney) {
    for _ in 0..<1500 where flight.phase != phase { flight.advance(seconds: 0.05, doorClosed: true, landingReady: true) }
    XCTAssertEqual(flight.phase, phase)
  }

  func testEveryPlanetHasDeterministicDryTownSpaceports() throws {
    for planet in system.planets {
      let terrain = planet.terrain, spawn = terrain.spawn()
      let p = try port(planet.index)
      XCTAssertTrue(p.isValid)
      XCTAssertEqual(RocketPort.nearest(to: spawn, terrain: terrain), p)
      let site = try XCTUnwrap(SettlementGenerator.site(at: BlockPosition(p.center), terrain: terrain))
      XCTAssertNotEqual(site.kind, .village); XCTAssertNotEqual(site.habitat, .aquatic)
      XCTAssertEqual(site.id, p.settlementID)
      XCTAssertNil(site.building(lotX: (p.x - site.x) / site.spacing, lotZ: (p.z - site.z) / site.spacing, terrain: terrain))
      for index in 0..<8 {
        let point = p.welcomePosition(index)
        XCTAssertNotNil(ResidentNavigation.standing(at: point, block: terrain.block))
        XCTAssertNotNil(ResidentNavigation.standing(at: point, block: { p.blocksTraffic($0) ? .basalt : terrain.block(at: $0) }))
        XCTAssertFalse(RocketCabin.obstructs(point - p.center, doorOpen: 1))
      }
    }
  }

  func testPadIsOpenAndChunkGenerationMatchesDirectQueries() throws {
    let p = try port(0), terrain = system.planets[0].terrain
    for chunk in p.chunks {
      let voxels = terrain.generate(chunk)
      for x in (p.x - 5)...(p.x + 5) { for z in (p.z - 5)...(p.z + 5) {
        guard BlockPosition(x, 0, z).chunk == chunk else { continue }
        for y in (p.floor - 1)...(p.floor + 18) {
          let expected = terrain.block(at: .init(x, y, z))
          XCTAssertEqual(voxels[x - chunk.x * 16, y, z - chunk.z * 16], expected)
          if y >= p.floor { XCTAssertEqual(expected, .air) }
          else { XCTAssertTrue(expected.isSolid) }
        }
      } }
    }
  }

  func testLandingSearchProtectsEditsAndFindsAnAlternatePad() throws {
    let p = try port(0), terrain = system.planets[0].terrain
    let wall = SavedEdit(position: .init(p.x, p.floor + 2, p.z), block: .brick)
    let hole = SavedEdit(position: .init(p.x, p.floor - 1, p.z), block: .air)
    XCTAssertFalse(p.accepts(edits: [wall])); XCTAssertFalse(p.accepts(edits: [hole]))
    XCTAssertFalse(p.accepts(edits: [.init(position: .init(p.x, p.floor + 40, p.z), block: .glass)]),
      "The entire ascent/descent column must clear player-built overhead structures")
    XCTAssertTrue(p.accepts(edits: [.init(position: wall.position, block: .air)]))
    XCTAssertTrue(p.accepts(edits: [.init(position: .init(p.x + 100, p.floor, p.z), block: .wood)]))
    let alternate = try XCTUnwrap(RocketPort.nearest(to: p.center, terrain: terrain, edits: [wall]))
    XCTAssertNotEqual(alternate.settlementID, p.settlementID)
  }

  func testDoorWallsWindowsAndPassengerContainment() {
    XCTAssertFalse(RocketCabin.obstructs([0, 0.02, 0], doorOpen: 0))
    XCTAssertTrue(RocketCabin.obstructs([0, 0.02, 4], doorOpen: 0))
    XCTAssertTrue(RocketCabin.obstructs([0, 0.02, 4], doorOpen: 0.8))
    XCTAssertFalse(RocketCabin.obstructs([0, 0.02, 4], doorOpen: 1))
    XCTAssertTrue(RocketCabin.inDoorway([0, 0.02, 4]))
    XCTAssertTrue(RocketCabin.obstructs([3.6, 1.5, 0], doorOpen: 1), "A clear window is still solid")
    XCTAssertTrue(RocketCabin.obstructs([0, 3.8, 0], doorOpen: 1), "Ceiling retains a jumping passenger")
    var p = SIMD3<Float>(0, 0.02, 0)
    for _ in 0..<500 { p = RocketCabin.passenger(p, movement: [1, 100, 1], deltaTime: 0.05) }
    XCTAssertTrue(RocketCabin.contains(p)); XCTAssertFalse(RocketCabin.obstructs(p, doorOpen: 0))
    let before = p
    p = RocketCabin.passenger(p, movement: [-1, 0, 0], deltaTime: 0)
    XCTAssertEqual(p, before)
  }

  func testCountdownInterlockPauseAndLoadingHold() throws {
    var trip = try flight()
    for _ in 0..<100 { trip.advance(seconds: 0.05, doorClosed: false, landingReady: true) }
    XCTAssertEqual(trip.elapsed, 0); XCTAssertEqual(trip.phase, .countdown)
    trip.advance(seconds: 0, doorClosed: true, landingReady: true)
    XCTAssertEqual(trip.elapsed, 0)
    reach(.cruise, flight: &trip)
    for _ in 0..<1000 { trip.advance(seconds: 0.05, doorClosed: true, landingReady: false) }
    XCTAssertEqual(trip.phase, .cruise); XCTAssertEqual(trip.elapsed, RocketPhase.cruise.duration)
    trip.advance(seconds: 0, doorClosed: true, landingReady: true)
    XCTAssertEqual(trip.phase, .cruise, "Pausing at the landing boundary must still freeze travel")
    trip.advance(seconds: 0.05, doorClosed: true, landingReady: true)
    XCTAssertEqual(trip.phase, .descent)
    trip.advance(seconds: 0.05, doorClosed: true, landingReady: true)
    let checkpoint = trip.elapsed
    for _ in 0..<400 { trip.advance(seconds: 0.05, doorClosed: true, landingReady: false) }
    XCTAssertEqual(trip.elapsed, checkpoint, "A resumed descent waits for its terrain and welcome party")
    reach(.landed, flight: &trip)
    XCTAssertEqual(trip.surfacePosition, trip.destination.center)
    XCTAssertEqual(trip.passenger, [1, 0.02, 2])
  }

  func testAllInterplanetaryRoutesClearMovingBodiesAndArriveAtCurrentOrbit() throws {
    let dummy = try port(0)
    for start in [0.0, 490.0, 2115.0] {
      for from in system.planets { for to in system.planets where to.index != from.index {
        var trip = RocketJourney(originPlanet: from.index, destinationPlanet: to.index,
          origin: dummy, destination: dummy, passenger: .zero)
        reach(.cruise, flight: &trip)
        var time = start
        XCTAssertEqual(trip.spacePosition(system: system, time: time), from.position(at: time) + [0, from.radius + 55, 0])
        for _ in 0..<565 {
          let location = trip.spacePosition(system: system, time: time)
          for planet in system.planets {
            XCTAssertGreaterThan(simd_distance(location, planet.position(at: time)), planet.radius + 20,
              "\(from.name) → \(to.name), near \(planet.name)")
          }
          trip.advance(seconds: 0.05, doorClosed: true, landingReady: false); time += 0.05
        }
        XCTAssertLessThan(simd_distance(trip.spacePosition(system: system, time: time),
          to.position(at: time) + [0, to.radius + 55, 0]), 0.001)
      } }
    }
  }

  func testEveryJourneyPhaseRoundTripsWithCorrectPlanetAndCabinOffset() throws {
    var trip = try flight()
    for phase in RocketPhase.allCases {
      reach(phase, flight: &trip)
      let p = trip.port.exit
      var save = WorldSave(seed: 8192, edits: [], player: [p.x, p.y, p.z], flying: false, heading: 0.7,
        selectedSlot: 0, planetIndex: trip.usesDestination ? trip.destinationPlanet : trip.originPlanet, rocket: trip)
      XCTAssertTrue(save.isValid)
      let restored = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
      XCTAssertEqual(restored.rocket?.phase, phase); XCTAssertEqual(restored.rocket?.passenger, trip.passenger)
      XCTAssertTrue(restored.isValid)
      save.planetIndex = 4; XCTAssertFalse(save.isValid)
      save.planetIndex = trip.usesDestination ? trip.destinationPlanet : trip.originPlanet
      save.space = .init(departing: system.planets[0], heading: 0)
      XCTAssertFalse(save.isValid)
    }
  }

  func testCorruptRocketCoordinatesAndCabinOffsetsAreRejectedWithoutOverflow() throws {
    let bad = RocketPort(settlementID: 1, town: "Town", x: .min, z: 0, floor: 30)
    XCTAssertFalse(bad.isValid)
    var trip = try flight(); trip.passenger = [.nan, 0, 0]
    XCTAssertFalse(trip.isValid)
    trip.passenger = [5, 0, 0]; XCTAssertFalse(trip.isValid)
  }

  func testStreetTrafficCanNavigateAroundReservedLandingHull() throws {
    let p = try port(0), terrain = system.planets[0].terrain
    let blocks: (BlockPosition) -> Block = { p.blocksTraffic($0) ? .basalt : terrain.block(at: $0) }
    XCTAssertTrue(p.blocksTraffic(.init(p.x, p.floor + 1, p.z)))
    XCTAssertFalse(p.blocksTraffic(BlockPosition(p.exit)))
    for i in 0..<8 { XCTAssertFalse(p.blocksTraffic(BlockPosition(p.welcomePosition(i)))) }
    let route = ResidentNavigation.path(from: p.center + [-7, 0.02, -1.5], to: p.center + [6.5, 0.02, -1.5], block: blocks)
    XCTAssertFalse(route.isEmpty)
    XCTAssertTrue(route.allSatisfy { !p.blocksTraffic(BlockPosition($0)) })
  }
}
