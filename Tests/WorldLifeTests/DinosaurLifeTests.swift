import XCTest
import simd
import WorldCore
@testable import WorldLife

@SimulationActor final class DinosaurLifeTests: XCTestCase {
  let loaded = Set((-3...3).flatMap { x in (-3...3).map { ChunkCoordinate(x, $0) } })
  let dry = WorldWeather.sample(seed: 0, time: 0, style: .verdant)
  func dino(_ id: UInt64, _ kind: DinosaurKind, _ point: SIMD3<Float>, group: UInt64 = 42, baby: Bool = false) -> FaunaSnapshot {
    .init(id: id, species: kind.rawValue, kind: nil, position: point, home: point, groupID: group, juvenile: baby)
  }
  func record(_ actor: FaunaSnapshot, hunger: Float = 0, thirst: Float = 0, social: Float = 0) -> FaunaRecord {
    var result = FaunaRecord(id: actor.id, species: actor.species, home: actor.home)
    result.hunger = hunger; result.thirst = thirst; result.fatigue = 0
    if let group = actor.groupID {
      result.social = .init(groupID: group, juvenile: actor.juvenile); result.social?.need = social
    }
    return result
  }
  func tick(_ life: FaunaSimulation, _ actors: [FaunaSnapshot], frame: Int, plants: [PlantInstance] = [],
    weather: WorldWeather? = nil, night: Bool = false, player: SIMD3<Float> = [1000, 30, 1000],
    block: (BlockPosition) -> Block = { $0.y < 30 ? .grass : .air }) {
    life.update(actors: actors, deltaTime: 0.1, time: 100 + Double(frame) * 0.1, player: player,
      offering: nil, weather: weather ?? dry, night: night, loaded: loaded, plants: { _ in plants }, block: block)
  }

  func testSeparatedJuvenileRejoinsParentButUrgentHungerComesFirst() async {
    let baby = dino(2, .parasaurolophus, [16.5, 30, 0.5], baby: true)
    let parent = dino(1, .parasaurolophus, [0.5, 30, 0.5])
    let life = FaunaSimulation(); life.restore([record(baby), record(parent)])
    tick(life, [baby, parent], frame: 0)
    XCTAssertEqual(life.directive(id: 2)?.goal, .rejoinGroup)
    XCTAssertEqual(life.directive(id: 2)?.partnerID, 1)
    XCTAssertLessThan(simd_distance(life.directive(id: 2)!.point.center, parent.position), 4)
    life.restore([record(baby, hunger: 0.95), record(parent)])
    tick(life, [baby, parent], frame: 1, plants: [.init(position: .init(17, 30, 0), kind: .fern)])
    XCTAssertEqual(life.directive(id: 2)?.goal, .forage)
  }

  func testSocializingRelievesNeedBuildsReciprocalBondsAndSurvivesRestore() async throws {
    let a = dino(1, .triceratops, [0.5, 30, 0.5]), b = dino(2, .triceratops, [2.5, 30, 1.5])
    let life = FaunaSimulation(); life.restore([record(a, social: 0.9), record(b, social: 0.9)])
    for n in 0..<27 { tick(life, [a, b], frame: n) }
    for (id, other): (UInt64, UInt64) in [(1, 2), (2, 1)] {
      let state = try XCTUnwrap(life.records.first { $0.id == id })
      XCTAssertLessThan(state.social!.need, 0.6)
      XCTAssertGreaterThan(state.social!.bonds.first { $0.other == other }!.affinity, 0.15)
      XCTAssertTrue(state.memory.experiences.contains { $0.kind == .socialized && $0.other == other })
    }
    let saved = try JSONDecoder().decode([FaunaRecord].self, from: JSONEncoder().encode(life.records))
    let restored = FaunaSimulation(); restored.restore(saved)
    XCTAssertEqual(restored.knownDinosaur(id: 1), .triceratops)
    XCTAssertEqual(restored.records.first { $0.id == 1 }?.social?.bonds, life.records.first { $0.id == 1 }?.social?.bonds)
  }

  func testRaptorsJoinLiveHuntsShareOneCaptureAndRememberCooperation() async throws {
    let a = dino(1, .velociraptor, [0.5, 30, 0.5]), b = dino(2, .velociraptor, [1.5, 30, 0.5])
    let rabbit = FaunaSnapshot(id: 9, species: "rabbit", kind: .rabbit, position: [1.5, 30, -0.5], home: [1.5, 30, -0.5])
    let life = FaunaSimulation(); life.restore([record(a, hunger: 0.9), record(b, hunger: 0.9)])
    var captures = 0
    life.onHunt = { id in guard id == 9 && captures == 0 else { return false }; captures += 1; return true }
    tick(life, [a, b, rabbit], frame: 0)
    XCTAssertEqual(life.directive(id: 1)?.goal, .hunt)
    XCTAssertEqual(life.directive(id: 2)?.goal, .joinHunt)
    tick(life, [a, b, rabbit], frame: 1)
    XCTAssertEqual(life.directive(id: 2)?.goal, .joinHunt, "Updating a moving prey must preserve the cooperative goal")
    XCTAssertNotEqual(life.directive(id: 1)?.point, life.directive(id: 2)?.point)
    for n in 2..<30 { tick(life, [a, b, rabbit], frame: n) }
    XCTAssertEqual(captures, 1); XCTAssertFalse(life.canSpawn(id: 9, time: 105))
    for id: UInt64 in [1, 2] {
      let state = try XCTUnwrap(life.records.first { $0.id == id })
      XCTAssertLessThan(state.hunger, 0.73)
      XCTAssertTrue(state.memory.experiences.contains { $0.kind == .hunted })
    }
    XCTAssertFalse(a.preysOn(b))
    XCTAssertFalse(a.preysOn(dino(12, .brachiosaurus, [2, 30, 2], group: 12)))
  }

  func testStrongHerdGuardsYoungAndActuallyDetersPredation() async {
    let parent = dino(1, .triceratops, [0.5, 30, 0.5])
    let ally = dino(2, .triceratops, [2.5, 30, 0.5])
    let baby = dino(3, .triceratops, [0.5, 30, 2.5], baby: true)
    let hunter = dino(4, .trex, [2.5, 30, 2.5], group: 90)
    let actors = [parent, ally, baby, hunter]
    let life = FaunaSimulation(); life.restore(actors.map { record($0, hunger: $0.id == 4 ? 0.95 : 0) })
    var captured = false; life.onHunt = { _ in captured = true; return true }
    for n in 0..<30 { tick(life, actors, frame: n) }
    XCTAssertEqual(life.directive(id: 1)?.goal, .protectYoung)
    XCTAssertEqual(life.directive(id: 2)?.goal, .protectYoung)
    XCTAssertFalse(captured)
    XCTAssertNil(life.directive(id: 4)?.preyID)
    XCTAssertTrue(life.records.first { $0.id == 3 }!.memory.experiences.contains { $0.kind == .danger })
  }

  func testWeakHerdFleesAndAlarmsReachCompanionsOutsideImmediateThreatRange() async {
    let a = dino(1, .parasaurolophus, [0.5, 30, 0.5])
    let distant = dino(2, .parasaurolophus, [-20.5, 30, 0.5])
    let rex = dino(3, .trex, [5.5, 30, 0.5], group: 90)
    let life = FaunaSimulation(); life.restore([a, distant, rex].map { record($0) })
    tick(life, [a, distant, rex], frame: 0)
    XCTAssertEqual(life.directive(id: 1)?.goal, .flee)
    XCTAssertEqual(life.directive(id: 2)?.goal, .flee)
    XCTAssertTrue(life.records.first { $0.id == 2 }!.memory.experiences.contains {
      $0.kind == .danger && $0.other == 3 && $0.detail.contains("warned")
    })
  }

  func testArmoredParentRecognizesThreatToBabyEvenWhenItIsTooLargeToBePrey() async {
    let parent = dino(1, .ankylosaurus, [0.5, 30, 0.5])
    let baby = dino(2, .ankylosaurus, [0.5, 30, -3.5], baby: true)
    let raptor = dino(3, .velociraptor, [0.5, 30, -5.5], group: 90)
    XCTAssertFalse(raptor.preysOn(parent)); XCTAssertTrue(raptor.preysOn(baby))
    let life = FaunaSimulation(); life.restore([parent, baby, raptor].map { record($0) })
    tick(life, [parent, baby, raptor], frame: 0)
    XCTAssertEqual(life.directive(id: 1)?.goal, .protectYoung)
    XCTAssertEqual(life.directive(id: 1)?.partnerID, 2)
  }

  func testParentCanGuardYoungAgainstVisitorAndSolitaryAdultsKeepSpace() async {
    let parent = dino(1, .trex, [0.5, 30, 0.5]), baby = dino(2, .trex, [0.5, 30, -3.5], baby: true)
    let family = FaunaSimulation(); family.restore([record(parent), record(baby)])
    tick(family, [parent, baby], frame: 0, player: [0.5, 30, -5.5])
    XCTAssertEqual(family.directive(id: 1)?.goal, .protectYoung)
    let a = dino(10, .ankylosaurus, [0.5, 30, 0.5], group: 10)
    let b = dino(11, .ankylosaurus, [4.5, 30, 0.5], group: 11)
    let solos = FaunaSimulation(); solos.restore([record(a), record(b)])
    tick(solos, [a, b], frame: 0)
    XCTAssertEqual(solos.directive(id: 10)?.goal, .patrol)
    XCTAssertGreaterThan(simd_distance(solos.directive(id: 10)!.point.center, b.position), simd_distance(a.position, b.position))
    XCTAssertNil(solos.records.first { $0.id == 10 }?.social?.bonds.first)
  }

  func testHerbivorousDinosaurActuallyEatsPlantsAndRemembersFood() async {
    let herbivore = dino(1, .brachiosaurus, [0.5, 30, 0.5])
    let life = FaunaSimulation(); life.restore([record(herbivore, hunger: 0.9)])
    let p = BlockPosition(1, 30, 0); var exists = true, meals = 0
    life.onEatPlant = { point, kind in
      guard exists, point == p, kind == .broadleaf else { return false }
      exists = false; meals += 1; return true
    }
    for n in 0..<30 { tick(life, [herbivore], frame: n, plants: exists ? [.init(position: p, kind: .broadleaf)] : []) }
    XCTAssertEqual(meals, 1)
    XCTAssertTrue(life.records[0].memory.experiences.contains { $0.kind == .foundFood && $0.point == p })
    XCTAssertLessThan(life.records[0].hunger, 0.6)
  }

  func testSpinosaurusChoosesFishWhileHerbivoresDoNotHunt() async {
    let spino = dino(1, .spinosaurus, [0.5, 30, 0.5])
    let fish = FaunaSnapshot(id: 2, species: "fish", kind: .fish, position: [0.5, 28, -5.5], home: [0.5, 28, -5.5])
    let life = FaunaSimulation(); life.restore([record(spino, hunger: 0.9)])
    tick(life, [spino, fish], frame: 0, block: { _ in .water })
    XCTAssertEqual(life.directive(id: 1)?.preyID, 2)
    XCTAssertEqual(life.directive(id: 1)?.goal, .hunt)
    XCTAssertFalse(dino(3, .stegosaurus, .zero).preysOn(fish))
  }

  func testTallDinosaurSeeksCoverItCanActuallyFitUnder() async throws {
    let rain = try XCTUnwrap((0..<100).map { WorldWeather.sample(seed: UInt64($0), time: 80, style: .verdant) }.first { $0.wet })
    let brachio = dino(1, .brachiosaurus, [0.5, 30, 0.5])
    let life = FaunaSimulation(); life.restore([record(brachio)])
    tick(life, [brachio], frame: 0, weather: rain) { p in
      p.y < 30 || (p.x == 3 && p.z == 0 && p.y == 35) || (p.x == -3 && p.z == 0 && p.y == 50) ? .stone : .air
    }
    XCTAssertEqual(life.directive(id: 1)?.goal, .shelter)
    XCTAssertEqual(life.directive(id: 1)?.point.x, -3, "A six-block roof cannot shelter a seventeen-block animal")
  }

  func testBlockedGuardPositionOffersEscapeInsteadOfImpossibleDefense() async {
    let parent = dino(1, .triceratops, [0.5, 30, 0.5])
    let baby = dino(2, .triceratops, [0.5, 30, -3.5], baby: true)
    let life = FaunaSimulation(); life.restore([record(parent), record(baby)])
    tick(life, [parent, baby], frame: 0, player: [0.5, 30, -5.5]) { p in
      p.y < 30 || p.z <= -6 ? .stone : .air
    }
    XCTAssertEqual(life.directive(id: 1)?.goal, .flee)
  }

  func testColossalFaunaUsesSharedThirstSleepAndMemoryWithoutLoadedChunks() async {
    let home = SIMD3<Float>(0.5, 30, 0.5)
    let giant = FaunaSnapshot(id: 50, species: "colossal_trex", kind: nil, position: home, home: home,
      distantOptions: ["drink_here": .init(.drink, at: .init(home), description: "Surveyed shoreline"),
        "home": .init(.sleep, at: .init(home), description: "Resting territory")], remoteWater: true)
    let life = FaunaSimulation(); var memory = record(giant, thirst: 0.95); memory.fatigue = 0.8
    life.restore([memory])
    for n in 0..<45 {
      life.update(actors: [giant], deltaTime: 0.1, time: 100 + Double(n) * 0.1, player: [10, 30, 10],
        offering: nil, weather: dry, night: true, loaded: [], plants: { _ in [] }, block: { _ in .stone })
    }
    XCTAssertLessThan(life.records[0].thirst, 0.2)
    XCTAssertTrue(life.records[0].memory.experiences.contains { $0.kind == .foundWater })
    XCTAssertEqual(life.directive(id: 50)?.goal, .sleep)
    XCTAssertLessThan(life.records[0].fatigue, 0.8)
  }
}
