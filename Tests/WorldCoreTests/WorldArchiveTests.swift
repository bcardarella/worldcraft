import XCTest

@testable import WorldCore

final class WorldArchiveTests: XCTestCase {
  func testOriginalSaveDecodesWithoutNewPlanetOrFlightFields() throws {
    let original =
      #"{"version":1,"seed":8192,"edits":[],"player":[1,30,1],"flying":false,"heading":0,"selectedSlot":0}"#
    let save = try JSONDecoder().decode(WorldSave.self, from: Data(original.utf8))
    XCTAssertTrue(save.isValid)
    XCTAssertNil(save.planetIndex)
    XCTAssertNil(save.space)
  }
  func testPlanetEditsAndSpaceFlightSurviveRoundTripIndependently() throws {
    let system = SolarSystem(seed: 8192)
    let edit = BlockPosition(10, -30, 20)
    let earth = SavedPlanet(
      index: 0, edits: [.init(position: edit, block: .wood)], player: [2, 70, 3], heading: 0,
      worldTime: 300)
    let dune = SavedPlanet(
      index: 1, edits: [.init(position: edit, block: .brick)], player: [7, 40, 9], heading: 1,
      worldTime: 900)
    let ship = SpaceFlight(departing: system.planets[0], heading: 0)
    let save = WorldSave(
      seed: 8192, edits: earth.edits, player: earth.player, flying: true, heading: 0,
      selectedSlot: 2,
      worldTime: 300, planetIndex: 0, visitedPlanets: [earth, dune], space: ship)
    XCTAssertTrue(save.isValid)
    let restored = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    XCTAssertTrue(restored.isValid)
    XCTAssertEqual(restored.visitedPlanets?[0].edits[0].block, .wood)
    XCTAssertEqual(restored.visitedPlanets?[1].edits[0].block, .brick)
    XCTAssertEqual(restored.space?.position, ship.position)
  }
  func testCorruptPlanetCoordinatesAndInvalidFlightAreRejected() {
    var save = WorldSave(
      seed: 1, edits: [], player: [0, 30, 0], flying: false, heading: 0, selectedSlot: 0)
    save.visitedPlanets = [
      .init(
        index: 2, edits: [.init(position: .init(Int.max, 10, 0), block: .stone)],
        player: [0, 30, 0], heading: 0, worldTime: 3)
    ]
    XCTAssertFalse(save.isValid)
    save.visitedPlanets = nil
    save.space = .init(departing: SolarSystem(seed: 1).planets[0], heading: 0)
    save.space?.velocity = [.nan, 0, 0]
    XCTAssertFalse(save.isValid)
  }

  func testAirplaneEraSaveRestoresAsCreativeFlight() throws {
    let original =
      #"{"version":1,"seed":8192,"edits":[],"player":[1,80,1],"flying":true,"heading":1,"selectedSlot":0,"flight":{"velocity":[4,8,-15],"heading":1,"pitch":0.2,"bank":0.4,"throttle":0.8,"stalled":false},"space":{"position":[0,350,0],"velocity":[10,20,-30],"heading":1,"pitch":0.3,"bank":0.5,"throttle":0.8,"originIndex":0,"clearedOrigin":false}}"#
    let save = try JSONDecoder().decode(WorldSave.self, from: Data(original.utf8))
    XCTAssertTrue(save.isValid)
    XCTAssertTrue(save.flying)
    var ship = try XCTUnwrap(save.space)
    let position = ship.position
    _ = ship.update(deltaTime: 0.05, movement: .zero, system: .init(seed: save.seed))
    XCTAssertNotEqual(ship.position, position)
    XCTAssertGreaterThan(ship.speed, 0)
    XCTAssertLessThan(ship.speed, sqrt(10 * 10 + 20 * 20 + 30 * 30))
  }
}
